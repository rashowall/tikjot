import Foundation
import JiraKit
import TikjotDomain
import TikjotPersistence

/// The app's data as the engine needs it. Implemented by the app model (and by tests).
public protocol SyncStore: Sendable {
    func context() async -> SyncContext
    func apply(_ changes: Changes) async throws
}

public struct SyncContext: Sendable {
    public var data: DataSnapshot
    public var ledger: Ledger
    public var lock: LockPolicy
    public var calendar: Calendar

    public init(data: DataSnapshot, ledger: Ledger, lock: LockPolicy, calendar: Calendar) {
        self.data = data; self.ledger = ledger; self.lock = lock; self.calendar = calendar
    }
}

// MARK: - Send

public struct SendOutcome: Sendable, Identifiable {
    public enum Result: Sendable, Equatable {
        case sent
        case failed(JiraError)
    }
    public var id: UUID { groupId }
    public let groupId: UUID
    public let action: ReviewPlan.Action
    public let result: Result
}

public struct SendReport: Sendable {
    public var outcomes: [SendOutcome] = []
    /// Set when sending stopped early (offline, signed out).
    public var stoppedBy: JiraError?
    /// The Jira connection that stopped it (a 401 there signs out that site, not another one).
    public var stoppedOn: UUID?
    /// What to undo (§11.11 "Undo after send").
    public var undo: [UndoStep] = []

    public var sentCount: Int { outcomes.filter { $0.result == .sent }.count }
    public var failed: [SendOutcome] { outcomes.filter { $0.result != .sent } }
}

public struct UndoStep: Sendable {
    public let groupId: UUID
    public let issueId: String
    public let instanceId: UUID
    public let action: ReviewPlan.Action
    public let worklogId: String
    public let previous: SentSnapshot?
    public let previousRemoteId: String?
    public let previousSentRaw: Seconds?
}

public enum SendProgress: Sendable {
    case started(UUID)
    case finished(UUID, SendOutcome.Result)
}

// MARK: - Refresh

public struct RefreshReport: Sendable {
    public var issuesChecked = 0
    public var imported = 0
    public var updated = 0
    public var conflicts = 0
    public var remoteDeleted = 0
    public var lockedChanges = 0
    /// Keys that moved (old → new) and whether their project changed.
    public var moved: [(old: String, new: String)] = []
    /// Jira project keys seen in worklogs without a project rule (first-run suggestions, §10.4).
    public var unmappedKeys: [String: String] = [:]
}

public enum RefreshProgress: Sendable {
    case issues(done: Int, total: Int)
}

public final class SyncEngine: Sendable {
    let store: any SyncStore
    let clientFor: @Sendable (UUID) async -> JiraClient?
    /// One writer at a time: a manual send, the automatic retry and undo never overlap (no double creates).
    let writeLock = AsyncLock()

    public init(store: any SyncStore, clientFor: @escaping @Sendable (UUID) async -> JiraClient?) {
        self.store = store
        self.clientFor = clientFor
    }

    /// Holds off every send, undo, refresh and conflict action until `resumeWrites` — while Delete all data or a
    /// restore replaces everything underneath. Always pair with `resumeWrites`.
    public func pauseWrites() async { await writeLock.lock() }
    public func resumeWrites() async { await writeLock.unlock() }

    /// Runs `body` as the only writer (see `writeLock`).
    private func locked<T>(_ body: () async throws -> T) async throws -> T {
        await writeLock.lock()
        do {
            let r = try await body()
            await writeLock.unlock()
            return r
        } catch {
            await writeLock.unlock()
            throw error
        }
    }

    // MARK: Send (§9.8)

    /// Sends the plan's items sequentially per instance; partial success is kept.
    /// Sends are serialized; each item is re-checked against the stored data first, so an item that an
    /// earlier (or overlapping) send already delivered is not written twice.
    public func send(_ items: [ReviewPlan.Item], progress: (@Sendable (SendProgress) -> Void)? = nil) async -> SendReport {
        await writeLock.lock()
        let report = await sendSerialized(items, progress: progress)
        await writeLock.unlock()
        return report
    }

    private func sendSerialized(_ items: [ReviewPlan.Item], progress: (@Sendable (SendProgress) -> Void)?) async -> SendReport {
        var report = SendReport()
        let byInstance = Dictionary(grouping: items, by: \.issue.instanceId)
        let instances = await store.context().data.instances
        for (instanceId, its) in byInstance {
            // Without the account id tikjot can't tell your worklogs from colleagues' — reconnect first.
            guard let client = await clientFor(instanceId),
                  let me = instances.first(where: { $0.id == instanceId })?.accountId, !me.isEmpty else {
                for i in its { report.outcomes.append(.init(groupId: i.groupId, action: i.action, result: .failed(.unauthorized))) }
                report.stoppedBy = .unauthorized
                report.stoppedOn = instanceId
                continue
            }
            for item in its {
                progress?(.started(item.groupId))
                let result = await sendOne(item, client: client, me: me, report: &report)
                progress?(.finished(item.groupId, result))
                report.outcomes.append(.init(groupId: item.groupId, action: item.action, result: result))
                if case .failed(let e) = result, e.isUnreachable || e == .unauthorized || e == .captcha || e.isSignInPage || e == .outcomeUnknown {
                    report.stoppedBy = e
                    report.stoppedOn = instanceId
                    break
                }
            }
        }
        return report
    }

    private func sendOne(_ item: ReviewPlan.Item, client: JiraClient, me: String, report: inout SendReport) async -> SendOutcome.Result {
        let ctx = await store.context()
        guard var g = ctx.data.groups.first(where: { $0.id == item.groupId }) else { return .failed(.notFound) }
        let draft = WorklogDraft(started: item.started, timeSpentSeconds: item.value, descriptions: item.descriptions,
                                 commentOverride: g.commentOverride)
        var changes = Changes()
        /// The create request went out (so a definite refusal means Jira has nothing from this group).
        var posted = false
        /// `g` learned something that must be stored even if a later step fails.
        var dirty = false
        do {
            switch item.action {
            case .create:
                // Fresh data wins over the plan: already in Jira (an earlier or overlapping send) → nothing to create.
                if g.remoteWorklogId != nil || g.syncState == .synced { return .sent }
                if g.createOutcomeUnknown, let attempt = g.remoteVersion {
                    // An earlier create may have reached Jira without an answer: look for it before writing again.
                    let known = Set(ctx.data.groups.filter { $0.instanceId == g.instanceId }.compactMap(\.remoteWorklogId))
                    let ws = try await client.worklogs(issueId: item.issue.issueId, startedAfter: attempt.startedAt.addingTimeInterval(-120))
                    if let w = Self.matchAttempt(attempt, in: ws, me: me, excluding: known) {
                        report.undo.append(UndoStep(groupId: g.id, issueId: item.issue.issueId, instanceId: item.issue.instanceId,
                                                    action: .create, worklogId: w.id, previous: nil, previousRemoteId: nil, previousSentRaw: nil))
                        apply(w, raw: item.raw, to: &g)
                        dirty = true
                        if !Self.same(w, draft) {
                            // Changed here since that attempt: bring the adopted worklog up to date.
                            let u = try await client.updateWorklog(issueId: item.issue.issueId, worklogId: w.id, draft)
                            apply(u, raw: item.raw, to: &g)
                        }
                        changes.upsertGroups = [g]
                        try? await store.apply(changes)
                        return .sent
                    }
                }
                // Remember what is being created before it goes out, so a lost answer (or a crash) can be matched later.
                g.remoteVersion = SentSnapshot(startedAt: draft.started, durationSeconds: draft.timeSpentSeconds, comment: draft.plainComment)
                var mark = Changes()
                mark.upsertGroups = [g]
                try? await store.apply(mark)
                posted = true
                let w = try await client.createWorklog(issueId: item.issue.issueId, draft)
                report.undo.append(UndoStep(groupId: g.id, issueId: item.issue.issueId, instanceId: item.issue.instanceId,
                                            action: .create, worklogId: w.id, previous: nil, previousRemoteId: nil, previousSentRaw: nil))
                apply(w, raw: item.raw, to: &g)
                changes.upsertGroups = [g]
            case .update:
                guard let wid = g.remoteWorklogId else { return .failed(.notFound) }
                try await checkAuthor(client: client, issueId: item.issue.issueId, worklogId: wid, me: me)
                let w = try await client.updateWorklog(issueId: item.issue.issueId, worklogId: wid, draft)
                report.undo.append(UndoStep(groupId: g.id, issueId: item.issue.issueId, instanceId: item.issue.instanceId,
                                            action: .update, worklogId: wid, previous: g.lastSent, previousRemoteId: wid, previousSentRaw: g.sentRaw))
                apply(w, raw: item.raw, to: &g)
                changes.upsertGroups = [g]
            case .delete:
                guard let wid = g.remoteWorklogId else {
                    if g.createOutcomeUnknown, let attempt = g.remoteVersion {
                        // An earlier create may have reached Jira without an answer: find that worklog and take it out.
                        let known = Set(ctx.data.groups.filter { $0.instanceId == g.instanceId }.compactMap(\.remoteWorklogId))
                        let ws = try await client.worklogs(issueId: item.issue.issueId, startedAfter: attempt.startedAt.addingTimeInterval(-120))
                        if let w = Self.matchAttempt(attempt, in: ws, me: me, excluding: known) {
                            do {
                                try await checkAuthor(client: client, issueId: item.issue.issueId, worklogId: w.id, me: me)
                                try await client.deleteWorklog(issueId: item.issue.issueId, worklogId: w.id)
                            } catch JiraError.notFound {}
                            let was = SentSnapshot(startedAt: w.started, durationSeconds: w.timeSpentSeconds, comment: w.comment)
                            report.undo.append(UndoStep(groupId: g.id, issueId: item.issue.issueId, instanceId: item.issue.instanceId,
                                                        action: .delete, worklogId: w.id, previous: was, previousRemoteId: w.id, previousSentRaw: nil))
                        }
                    }
                    changes.deleteGroups = [g.id]
                    try? await store.apply(changes)
                    return .sent
                }
                do {
                    try await checkAuthor(client: client, issueId: item.issue.issueId, worklogId: wid, me: me)
                    try await client.deleteWorklog(issueId: item.issue.issueId, worklogId: wid)
                } catch JiraError.notFound {
                    // Already gone in Jira — that's the goal.
                }
                report.undo.append(UndoStep(groupId: g.id, issueId: item.issue.issueId, instanceId: item.issue.instanceId,
                                            action: .delete, worklogId: wid, previous: g.lastSent, previousRemoteId: wid, previousSentRaw: g.sentRaw))
                changes.deleteGroups = [g.id]
            }
            try? await store.apply(changes)
            return .sent
        } catch let e as JiraError {
            if posted && !e.mayHaveReachedJira {
                // Jira refused the create outright: nothing of it exists there.
                g.remoteVersion = nil
                dirty = true
            }
            let quiet = e.isUnreachable || e.isSignInPage || e == .outcomeUnknown
            if e == .notFound && item.action == .update {
                g.syncState = .remoteDeleted
            } else if !quiet {
                g.syncState = .error
                g.lastError = SyncErrorInfo(code: e.code, message: e.message)
            }
            if !quiet || dirty {
                var c = Changes()
                c.upsertGroups = [g]
                try? await store.apply(c)
            }
            return .failed(e)
        } catch {
            return .failed(.invalidResponse(error.localizedDescription))
        }
    }

    /// Never change a worklog that isn't yours (a stale or wrongly linked id).
    private func checkAuthor(client: JiraClient, issueId: String, worklogId: String, me: String) async throws {
        let current = try await client.worklog(issueId: issueId, worklogId: worklogId)
        guard current.authorId == me else {
            throw JiraError.forbidden("This worklog belongs to someone else in Jira — tikjot won't change it.")
        }
    }

    /// The worklog an earlier create left in Jira: yours, same duration, started within a minute, not linked to
    /// another group; the one with the same comment first.
    static func matchAttempt(_ a: SentSnapshot, in ws: [JiraWorklog], me: String, excluding known: Set<String>) -> JiraWorklog? {
        let candidates = ws.filter { $0.authorId == me && !known.contains($0.id) && $0.timeSpentSeconds == a.durationSeconds
            && abs($0.started.timeIntervalSince(a.startedAt)) <= 60 }
        return candidates.first { JiraComment.normalized($0.comment) == JiraComment.normalized(a.comment) } ?? candidates.first
    }

    static func same(_ w: JiraWorklog, _ d: WorklogDraft) -> Bool {
        w.timeSpentSeconds == d.timeSpentSeconds && abs(w.started.timeIntervalSince(d.started)) < 60
            && JiraComment.normalized(w.comment) == JiraComment.normalized(d.plainComment)
    }

    private func apply(_ w: JiraWorklog, raw: Seconds, to g: inout WorklogGroup) {
        g.remoteWorklogId = w.id
        g.remoteUpdated = w.updated
        g.lastSent = SentSnapshot(startedAt: w.started, durationSeconds: w.timeSpentSeconds, comment: w.comment)
        g.sentRaw = raw
        g.remoteVersion = nil
        g.syncState = .synced
        g.lastError = nil
        g.commentOverrideStale = false
        g.updatedAt = Date()
    }

    /// Undo after send: created worklogs are deleted again, updates reverted, deletions re-created.
    /// Returns how many steps were undone; a step that failed leaves the group as it is (still linked to Jira).
    public func undo(_ steps: [UndoStep], progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Int {
        await writeLock.lock()
        let done = await undoSerialized(steps, progress: progress)
        await writeLock.unlock()
        return done
    }

    private func undoSerialized(_ steps: [UndoStep], progress: (@Sendable (Int, Int) -> Void)?) async -> Int {
        var done = 0
        for (n, s) in steps.enumerated() {
            progress?(n, steps.count)
            guard let client = await clientFor(s.instanceId) else { continue }
            let ctx = await store.context()
            var g = ctx.data.groups.first { $0.id == s.groupId }
            var c = Changes()
            do {
                switch s.action {
                case .create:
                    // Only a delete Jira confirmed (or a worklog already gone) unlinks the group; any other
                    // failure keeps the remote id so the worklog isn't created a second time later.
                    do {
                        try await client.deleteWorklog(issueId: s.issueId, worklogId: s.worklogId)
                    } catch JiraError.notFound {}
                    if var x = g {
                        x.remoteWorklogId = nil; x.remoteUpdated = nil; x.lastSent = nil; x.sentRaw = nil
                        x.syncState = .unsent
                        g = x
                    }
                case .update:
                    if let p = s.previous {
                        let w = try await client.updateWorklog(issueId: s.issueId, worklogId: s.worklogId,
                                                               WorklogDraft(started: p.startedAt, timeSpentSeconds: p.durationSeconds, descriptions: [], commentOverride: p.comment))
                        if var x = g {
                            x.lastSent = p; x.remoteUpdated = w.updated; x.sentRaw = s.previousSentRaw
                            x.syncState = .synced
                            g = x
                        }
                    }
                case .delete:
                    if let p = s.previous {
                        let w = try await client.createWorklog(issueId: s.issueId,
                                                               WorklogDraft(started: p.startedAt, timeSpentSeconds: p.durationSeconds, descriptions: [], commentOverride: p.comment))
                        // The local entries are gone; keep the worklog as an imported entry so nothing is lost.
                        let entry = TimeEntry(start: p.startedAt, end: p.startedAt.addingTimeInterval(TimeInterval(p.durationSeconds)),
                                              instanceId: s.instanceId, issueId: s.issueId,
                                              projectId: projectFor(ctx.data, instanceId: s.instanceId, issueId: s.issueId),
                                              description: CommentRenderer.description(fromPlain: p.comment), source: .imported)
                        var ng = WorklogGroup(instanceId: s.instanceId, issueId: s.issueId, localDate: LocalDate(p.startedAt, calendar: ctx.calendar),
                                              kind: .imported, remoteWorklogId: w.id, remoteUpdated: w.updated,
                                              lastSent: SentSnapshot(startedAt: w.started, durationSeconds: w.timeSpentSeconds, comment: w.comment),
                                              sentRaw: p.durationSeconds, syncState: .synced)
                        ng.id = s.groupId
                        var e = entry
                        e.worklogGroupId = ng.id
                        c.upsertEntries = [e]
                        g = ng
                    }
                }
                if let g { c.upsertGroups = [g] }
                try? await store.apply(c)
                done += 1
            } catch {
                continue
            }
        }
        progress?(steps.count, steps.count)
        return done
    }

    // MARK: Conflicts (§9.7) & remote deletions (§9.5)

    /// Take Jira's version: local entries collapse into one entry spanning `started` + duration with Jira's comment.
    public func takeJira(groupId: UUID) async throws { try await locked { try await takeJiraLocked(groupId: groupId) } }

    private func takeJiraLocked(groupId: UUID) async throws {
        let ctx = await store.context()
        guard var g = ctx.data.groups.first(where: { $0.id == groupId }), let remote = g.remoteVersion ?? g.lastSent else { return }
        let entries = ctx.data.entries.filter { $0.worklogGroupId == g.id }
        var c = Changes()
        c.deleteEntries = entries.map(\.id)
        let template = entries.first
        let e = TimeEntry(start: remote.startedAt, end: remote.startedAt.addingTimeInterval(TimeInterval(remote.durationSeconds)),
                          instanceId: g.instanceId, issueId: g.issueId,
                          projectId: template?.projectId ?? projectFor(ctx.data, instanceId: g.instanceId, issueId: g.issueId),
                          description: CommentRenderer.multiLineDescription(fromPlain: remote.comment), source: template?.source ?? .local,
                          worklogGroupId: g.id)
        c.upsertEntries = [e]
        g.lastSent = remote
        g.sentRaw = remote.durationSeconds
        g.remoteVersion = nil
        g.syncState = .synced
        g.commentOverride = nil
        g.localDate = LocalDate(remote.startedAt, calendar: ctx.calendar)
        c.upsertGroups = [g]
        try await store.apply(c)
    }

    /// A failed update (the worklog is in Jira, Jira refuses the change — e.g. the task is closed): leave Jira as it
    /// is and follow it here (beta 2026-10-25). Same time → only the comment differs: the worklog keeps Jira's comment
    /// (`commentOverride`), the entries and their descriptions stay as they are. Different time → as Take Jira's.
    public func keepJira(groupId: UUID) async throws { try await locked { try await keepJiraLocked(groupId: groupId) } }

    private func keepJiraLocked(groupId: UUID) async throws {
        let ctx = await store.context()
        guard var g = ctx.data.groups.first(where: { $0.id == groupId }), g.remoteWorklogId != nil, let sent = g.lastSent else { return }
        let line = ctx.ledger.lines(on: g.localDate).first { $0.group?.id == g.id }
        if let line, line.value == sent.durationSeconds, abs(line.started.timeIntervalSince(sent.startedAt)) < 60 {
            g.commentOverride = sent.comment
            g.commentOverrideStale = false
            g.syncState = .synced
            g.lastError = nil
            var c = Changes()
            c.upsertGroups = [g]
            try await store.apply(c)
        } else {
            g.lastError = nil
            var c = Changes()
            c.upsertGroups = [g]
            try await store.apply(c)
            try await takeJiraLocked(groupId: groupId)
        }
    }

    /// Keep mine: Jira's version becomes the base, so the next send overwrites it.
    public func keepMine(groupId: UUID) async throws { try await locked { try await keepMineLocked(groupId: groupId) } }

    private func keepMineLocked(groupId: UUID) async throws {
        let ctx = await store.context()
        guard var g = ctx.data.groups.first(where: { $0.id == groupId }) else { return }
        if let r = g.remoteVersion { g.lastSent = r; g.sentRaw = nil }
        g.remoteVersion = nil
        g.syncState = .synced
        var c = Changes()
        c.upsertGroups = [g]
        try await store.apply(c)
    }

    /// Deleted in Jira → send again (new worklog on next send).
    public func sendAgain(groupId: UUID) async throws { try await locked { try await sendAgainLocked(groupId: groupId) } }

    private func sendAgainLocked(groupId: UUID) async throws {
        let ctx = await store.context()
        guard var g = ctx.data.groups.first(where: { $0.id == groupId }) else { return }
        g.remoteWorklogId = nil; g.remoteUpdated = nil; g.lastSent = nil; g.sentRaw = nil; g.remoteVersion = nil; g.syncState = .unsent
        if g.kind == .imported { g.kind = .app }
        var c = Changes()
        c.upsertGroups = [g]
        // Imported entries become local ones.
        c.upsertEntries = ctx.data.entries.filter { $0.worklogGroupId == g.id && $0.source == .imported }.map { var e = $0; e.source = .local; return e }
        try await store.apply(c)
    }

    /// Deleted in Jira → remove here too.
    public func removeLocally(groupId: UUID) async throws { try await locked { try await removeLocallyLocked(groupId: groupId) } }

    private func removeLocallyLocked(groupId: UUID) async throws {
        let ctx = await store.context()
        var c = Changes()
        c.deleteEntries = ctx.data.entries.filter { $0.worklogGroupId == groupId }.map(\.id)
        c.deleteGroups = [groupId]
        try await store.apply(c)
    }

    /// Retry a failed group: back to unsent/synced so it's planned again.
    public func clearError(groupId: UUID) async throws { try await locked { try await clearErrorLocked(groupId: groupId) } }

    private func clearErrorLocked(groupId: UUID) async throws {
        let ctx = await store.context()
        guard var g = ctx.data.groups.first(where: { $0.id == groupId }) else { return }
        g.lastError = nil
        g.syncState = g.remoteWorklogId == nil ? .unsent : .synced
        var c = Changes()
        c.upsertGroups = [g]
        try await store.apply(c)
    }

    // MARK: Refresh / import (§9.5, §9.9, §9.10)

    public func refresh(instanceId: UUID, now: Date = Date(), progress: (@Sendable (RefreshProgress) -> Void)? = nil) async throws -> RefreshReport {
        // Not while a send is writing: a worklog it is creating would otherwise come back as an import.
        await writeLock.lock()
        do {
            let r = try await refreshSerialized(instanceId: instanceId, now: now, progress: progress)
            await writeLock.unlock()
            return r
        } catch {
            await writeLock.unlock()
            throw error
        }
    }

    private func refreshSerialized(instanceId: UUID, now: Date, progress: (@Sendable (RefreshProgress) -> Void)?) async throws -> RefreshReport {
        guard let client = await clientFor(instanceId) else { throw JiraError.unauthorized }
        var ctx = await store.context()
        guard var instance = ctx.data.instances.first(where: { $0.id == instanceId }), instance.status != .archived else {
            return RefreshReport()
        }
        // Without the account id every colleague's worklog would look like yours — reconnect first.
        guard let me = instance.accountId, !me.isEmpty else { throw JiraError.unauthorized }
        var report = RefreshReport()
        let cal = ctx.calendar
        let historyStart = (instance.historyStartDate ?? ctx.ledger.today.firstOfMonth).start(in: cal)
        let cursor = instance.syncCursor ?? historyStart
        let startedAt = now

        // 1. Issues with my worklogs updated since the cursor. Jira reads JQL dates in your Jira profile's time zone
        // (minute precision): write them there, a few minutes early.
        let jiraZone = instance.jiraTimeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        let since = "updated >= \"\(JiraDate.jql(cursor.addingTimeInterval(-5 * 60), timeZone: jiraZone))\""
        var issues = try await client.search(jql: "worklogAuthor = currentUser() AND \(since)")
        // 2. Issues of known worklogs in the editable window (catches deletions of my only worklog on an issue).
        let editableFrom = ctx.ledger.today.firstOfMonth.adding(months: -1)
        let knownIds = Set(ctx.data.groups.filter { $0.instanceId == instanceId && $0.remoteWorklogId != nil && $0.localDate >= editableFrom }.map(\.issueId))
            .subtracting(issues.map(\.id))
        for chunk in Array(knownIds).chunked(50) where !chunk.isEmpty {
            issues += try await searchIds(chunk, client: client, and: since)
        }
        var changes = Changes()
        // Creates whose answer was lost: a matching worklog in Jira is theirs, not a new import.
        var pendingCreates = ctx.data.groups.filter { $0.instanceId == instanceId && $0.createOutcomeUnknown }
        var issueCache = Dictionary(ctx.data.issues.filter { $0.instanceId == instanceId }.map { ($0.issueId, $0) }, uniquingKeysWith: { a, _ in a })
        let rules = ctx.data.rules.filter { $0.instanceId == instanceId }
        var groupsByRemote = Dictionary(ctx.data.groups.filter { $0.instanceId == instanceId && $0.remoteWorklogId != nil }.map { ($0.remoteWorklogId!, $0) }, uniquingKeysWith: { a, _ in a })
        let entriesByGroup = Dictionary(grouping: ctx.data.entries.filter { $0.worklogGroupId != nil }, by: { $0.worklogGroupId! })

        for (n, ji) in issues.enumerated() {
            progress?(.issues(done: n, total: issues.count))
            report.issuesChecked += 1
            // Issue cache + identity changes.
            var cached = issueCache[ji.id] ?? Issue(instanceId: instanceId, issueId: ji.id, key: ji.key, summary: ji.summary)
            if cached.key != ji.key && issueCache[ji.id] != nil {
                report.moved.append((cached.key, ji.key))
                let newProject = rules.first { $0.value == Issue.projectKey(of: ji.key) }?.projectId
                if let newProject {
                    for var e in ctx.data.entries where e.instanceId == instanceId && e.issueId == ji.id && e.projectId != newProject
                        && !ctx.lock.isLocked(LocalDate(e.start, calendar: cal), today: ctx.ledger.today) {
                        e.projectId = newProject
                        changes.upsertEntries.append(e)
                    }
                }
            }
            update(&cached, from: ji, me: me, now: now)
            cached.sources.insert("logged")
            issueCache[ji.id] = cached
            changes.upsertIssues.append(cached)
            if rules.first(where: { $0.value == ji.projectKey }) == nil { report.unmappedKeys[ji.projectKey] = ji.projectName ?? ji.projectKey }

            let worklogs = try await client.worklogs(issueId: ji.id, startedAfter: historyStart).filter { $0.authorId == me }
            let remoteIds = Set(worklogs.map(\.id))

            for w in worklogs {
                let day = LocalDate(w.started, calendar: cal)
                let locked = ctx.lock.isLocked(day, today: ctx.ledger.today)
                let remote = SentSnapshot(startedAt: w.started, durationSeconds: w.timeSpentSeconds, comment: w.comment)
                if var g = groupsByRemote[w.id] {
                    // Known worklog.
                    guard g.remoteUpdated != w.updated else { continue }
                    let same = g.lastSent.map { $0.durationSeconds == remote.durationSeconds && JiraComment.normalized($0.comment) == JiraComment.normalized(remote.comment)
                        && abs($0.startedAt.timeIntervalSince(remote.startedAt)) < 60 } ?? false
                    g.remoteUpdated = w.updated
                    if same {
                        changes.upsertGroups.append(g)
                        groupsByRemote[w.id] = g
                        continue
                    }
                    if locked || g.kind == .imported && !importedEdited(g, entriesByGroup[g.id] ?? [], ctx) {
                        // Jira wins silently (locked, or an imported worklog nobody touched here).
                        if locked { g.changedInJiraWas = g.lastSent?.durationSeconds; report.lockedChanges += 1 } else { report.updated += 1 }
                        g.lastSent = remote
                        g.sentRaw = remote.durationSeconds
                        g.remoteVersion = nil
                        let es = entriesByGroup[g.id] ?? []
                        changes.deleteEntries += es.map(\.id)
                        var e = TimeEntry(start: w.started, end: w.started.addingTimeInterval(TimeInterval(w.timeSpentSeconds)),
                                          instanceId: instanceId, issueId: ji.id,
                                          projectId: es.first?.projectId ?? rules.first { $0.value == ji.projectKey }?.projectId,
                                          description: CommentRenderer.description(fromPlain: w.comment), source: es.first?.source ?? .imported)
                        e.worklogGroupId = g.id
                        changes.upsertEntries.append(e)
                        g.localDate = day
                        if g.syncState != .locked { g.syncState = .synced }
                    } else {
                        g.remoteVersion = remote
                        g.syncState = .conflict
                        report.conflicts += 1
                    }
                    changes.upsertGroups.append(g)
                    groupsByRemote[w.id] = g
                } else {
                    if let i = pendingCreates.firstIndex(where: { $0.issueId == ji.id && $0.remoteVersion.map { a in
                        Self.matchAttempt(a, in: [w], me: me, excluding: Set(groupsByRemote.keys)) != nil } ?? false }) {
                        // The worklog of a create whose answer was lost: link it, don't import a twin.
                        var g = pendingCreates.remove(at: i)
                        g.remoteWorklogId = w.id
                        g.remoteUpdated = w.updated
                        g.lastSent = remote
                        g.sentRaw = nil
                        g.remoteVersion = nil
                        g.lastError = nil
                        // Entries removed meanwhile: it stays marked for deletion, now with the worklog to delete.
                        if g.syncState != .pendingDelete { g.syncState = .synced }
                        changes.upsertGroups.append(g)
                        groupsByRemote[w.id] = g
                        continue
                    }
                    // Unknown worklog → imported entry (adoption happens when the user edits it).
                    if let succ = instance.successorOf, let date = instance.successionDate, day < date,
                       ctx.data.groups.contains(where: { $0.instanceId == succ && $0.localDate == day && $0.lastSent?.durationSeconds == w.timeSpentSeconds }) {
                        continue // copy of an on-prem worklog already counted on the archived instance
                    }
                    let g = WorklogGroup(instanceId: instanceId, issueId: ji.id, localDate: day, kind: .imported,
                                         remoteWorklogId: w.id, remoteUpdated: w.updated, lastSent: remote,
                                         sentRaw: w.timeSpentSeconds, syncState: .synced)
                    let e = TimeEntry(start: w.started, end: w.started.addingTimeInterval(TimeInterval(w.timeSpentSeconds)),
                                      instanceId: instanceId, issueId: ji.id,
                                      projectId: rules.first { $0.value == ji.projectKey }?.projectId,
                                      description: CommentRenderer.description(fromPlain: w.comment), source: .imported,
                                      worklogGroupId: g.id)
                    changes.upsertGroups.append(g)
                    changes.upsertEntries.append(e)
                    groupsByRemote[w.id] = g
                    report.imported += 1
                }
            }
            // Known worklogs of this issue that are gone in Jira.
            for g in groupsByRemote.values where g.issueId == ji.id && !remoteIds.contains(g.remoteWorklogId!)
                && g.syncState != .pendingDelete && g.lastSent.map({ $0.startedAt >= historyStart }) ?? true {
                var x = g
                if ctx.lock.isLocked(g.localDate, today: ctx.ledger.today) {
                    changes.deleteEntries += (entriesByGroup[g.id] ?? []).map(\.id)
                    changes.deleteGroups.append(g.id)
                    report.lockedChanges += 1
                } else if g.kind == .imported && !importedEdited(g, entriesByGroup[g.id] ?? [], ctx) {
                    changes.deleteEntries += (entriesByGroup[g.id] ?? []).map(\.id)
                    changes.deleteGroups.append(g.id)
                    report.remoteDeleted += 1
                } else {
                    x.syncState = .remoteDeleted
                    changes.upsertGroups.append(x)
                    report.remoteDeleted += 1
                }
            }
        }
        progress?(.issues(done: issues.count, total: issues.count))
        instance.syncCursor = startedAt
        instance.lastSyncAt = now
        instance.status = .active
        changes.upsertInstances = [instance]
        try await store.apply(changes)
        ctx = await store.context()
        return report
    }

    private func importedEdited(_ g: WorklogGroup, _ entries: [TimeEntry], _ ctx: SyncContext) -> Bool {
        guard let sent = g.lastSent else { return true }
        let raw = entries.reduce(0) { $0 + $1.duration(now: ctx.ledger.now) }
        let desc = entries.map(\.description).joined(separator: "; ")
        return raw != sent.durationSeconds || desc != CommentRenderer.description(fromPlain: sent.comment)
            || abs((entries.first?.start ?? sent.startedAt).timeIntervalSince(sent.startedAt)) >= 60
    }

    func update(_ c: inout Issue, from ji: JiraIssue, me: String?, now: Date) {
        c.key = ji.key
        c.summary = ji.summary
        c.issueType = ji.issueType
        c.statusName = ji.statusName
        c.statusCategory = ji.statusCategory
        c.parentKey = ji.parentKey
        c.parentSummary = ji.parentSummary
        c.projectName = ji.projectName ?? c.projectName
        if let me { c.assignedToMe = ji.assigneeId == me }
        c.originalEstimateSeconds = ji.originalEstimateSeconds
        c.timeSpentSeconds = ji.timeSpentSeconds
        c.updated = ji.updated
        c.availability = .ok
        c.fetchedAt = now
    }

    func projectFor(_ data: DataSnapshot, instanceId: UUID, issueId: String) -> UUID? {
        guard let key = data.issues.first(where: { $0.instanceId == instanceId && $0.issueId == issueId })?.projectKey else { return nil }
        return data.rules.first { $0.instanceId == instanceId && $0.value == key }?.projectId
    }

    // MARK: Import preview (onboarding "Bring in your history")

    public struct ImportPreview: Sendable, Equatable {
        public var tasks: Int
        /// Jira project key → name.
        public var projects: [String: String]
    }

    /// Tasks with your worklogs since `from` and the Jira projects they belong to — one search, no worklogs fetched.
    public func previewImport(instanceId: UUID, from: LocalDate) async throws -> ImportPreview {
        guard let client = await clientFor(instanceId) else { throw JiraError.unauthorized }
        let issues = try await client.search(jql: "worklogAuthor = currentUser() AND worklogDate >= \"\(from.description)\"", limit: 5000)
        var projects: [String: String] = [:]
        for i in issues { projects[i.projectKey] = i.projectName ?? i.projectKey }
        return ImportPreview(tasks: issues.count, projects: projects)
    }

    // MARK: Issue metadata & suggestions sources (§9.9, §10)

    /// Refresh status/estimate/spent of issues visible on screen; marks deleted ones unavailable (§9.10).
    public func refreshIssues(instanceId: UUID, issueIds: [String], now: Date = Date()) async throws {
        guard let client = await clientFor(instanceId), !issueIds.isEmpty else { return }
        let ctx = await store.context()
        let me = ctx.data.instances.first { $0.id == instanceId }?.accountId
        var cache = Dictionary(ctx.data.issues.filter { $0.instanceId == instanceId }.map { ($0.issueId, $0) }, uniquingKeysWith: { a, _ in a })
        var c = Changes()
        for chunk in issueIds.chunked(50) {
            let found = try await searchIds(chunk, client: client)
            let foundIds = Set(found.map(\.id))
            for ji in found {
                var x = cache[ji.id] ?? Issue(instanceId: instanceId, issueId: ji.id, key: ji.key, summary: ji.summary)
                update(&x, from: ji, me: me, now: now)
                cache[ji.id] = x
                c.upsertIssues.append(x)
            }
            for id in chunk where !foundIds.contains(id) {
                guard var x = cache[id] else { continue }
                // Search runs on Jira's index, which can lag behind the tasks themselves (just created or moved,
                // Data Center reindexing). Ask for the task itself before calling it gone: only "not found" or
                // "no permission" mean unavailable; any other failure leaves it as it was.
                do {
                    let ji = try await client.issue(id)
                    update(&x, from: ji, me: me, now: now)
                } catch JiraError.notFound {
                    x.availability = .deleted
                    x.fetchedAt = now
                } catch JiraError.forbidden {
                    x.availability = .deleted
                    x.fetchedAt = now
                } catch {
                    continue
                }
                cache[id] = x
                c.upsertIssues.append(x)
            }
        }
        try await store.apply(c)
    }

    /// `issueId in (…)`. Jira rejects the whole query (400) when one task was deleted or is no longer
    /// visible to you, so on that error it asks one by one and leaves those out.
    func searchIds(_ ids: [String], client: JiraClient, and clause: String? = nil) async throws -> [JiraIssue] {
        // Ids go into the JQL as they are: only digits ever do.
        let ids = ids.filter(JiraIdentifier.isId)
        guard !ids.isEmpty else { return [] }
        func jql(_ list: [String]) -> String { "issueId in (\(list.joined(separator: ",")))" + (clause.map { " AND \($0)" } ?? "") }
        do {
            return try await client.search(jql: jql(ids))
        } catch JiraError.validation where ids.count > 1 {
            var out: [JiraIssue] = []
            for id in ids {
                do { out += try await client.search(jql: jql([id])) } catch JiraError.validation {}
            }
            return out
        } catch JiraError.validation {
            return []
        }
    }

    /// Issues assigned to me (not done) → suggestion source "assigned".
    public func refreshAssigned(instanceId: UUID, now: Date = Date()) async throws {
        guard let client = await clientFor(instanceId) else { return }
        let ctx = await store.context()
        let me = ctx.data.instances.first { $0.id == instanceId }?.accountId
        let found = try await client.search(jql: "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC", limit: 100)
        var cache = Dictionary(ctx.data.issues.filter { $0.instanceId == instanceId }.map { ($0.issueId, $0) }, uniquingKeysWith: { a, _ in a })
        var c = Changes()
        let foundIds = Set(found.map(\.id))
        for ji in found {
            var x = cache[ji.id] ?? Issue(instanceId: instanceId, issueId: ji.id, key: ji.key, summary: ji.summary)
            update(&x, from: ji, me: me, now: now)
            x.assignedToMe = true
            x.sources.insert("assigned")
            cache[ji.id] = x
            c.upsertIssues.append(x)
        }
        for var x in cache.values where x.assignedToMe && !foundIds.contains(x.issueId) {
            x.assignedToMe = false
            x.sources.remove("assigned")
            c.upsertIssues.append(x)
        }
        try await store.apply(c)
    }

    /// Saved filters / JQL: results cached and boosted in search (§6.10).
    public func refreshSource(_ source: SuggestionSource, now: Date = Date()) async throws {
        guard let client = await clientFor(source.instanceId) else { return }
        let jql = source.kind == .jql ? source.value : try await client.filterJQL(id: source.value).jql
        let found = try await client.search(jql: jql, limit: 200)
        let ctx = await store.context()
        let me = ctx.data.instances.first { $0.id == source.instanceId }?.accountId
        var cache = Dictionary(ctx.data.issues.filter { $0.instanceId == source.instanceId }.map { ($0.issueId, $0) }, uniquingKeysWith: { a, _ in a })
        var c = Changes()
        for ji in found {
            var x = cache[ji.id] ?? Issue(instanceId: source.instanceId, issueId: ji.id, key: ji.key, summary: ji.summary)
            update(&x, from: ji, me: me, now: now)
            x.sources.insert("filter:\(source.id.uuidString)")
            cache[ji.id] = x
            c.upsertIssues.append(x)
        }
        try await store.apply(c)
    }

    /// Remote search merged into the cache (§10.2). Exact keys are fetched directly.
    public func search(instanceId: UUID, text: String, now: Date = Date()) async throws -> [Issue] {
        guard let client = await clientFor(instanceId) else { return [] }
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var found: [JiraIssue] = []
        // Found among the user's own worklogs — marked "logged" so the picker ranks them as yours.
        var mine = Set<String>()
        if q.range(of: #"^[A-Za-z][A-Za-z0-9_]+-\d+$"#, options: .regularExpression) != nil {
            // A key that isn't there (404, no access) finds nothing; Jira not answering is thrown, so the picker can say so.
            do { found = [try await client.issue(q.uppercased())] } catch JiraError.notFound {} catch JiraError.forbidden {} catch JiraError.validation {}
        } else {
            let escaped = Self.jqlString(q)
            // Something that looks like a project key ("WEB", "pay_platform"): the tasks you logged in that project
            // (closed ones too), then its open tasks. Jira answers 400 for an unknown project — then it simply isn't one.
            if q.range(of: #"^[A-Za-z][A-Za-z0-9_]{1,19}$"#, options: .regularExpression) != nil {
                let project = Self.jqlString(q.uppercased())
                if let logged = try? await client.search(jql: "project = \"\(project)\" AND worklogAuthor = currentUser() ORDER BY updated DESC", maxResults: 20, limit: 20) {
                    found = logged
                    mine = Set(logged.map(\.id))
                }
                if let inProject = try? await client.search(jql: "project = \"\(project)\" AND statusCategory != Done ORDER BY updated DESC", maxResults: 20, limit: 20) {
                    found += inProject.filter { !mine.contains($0.id) }
                }
            }
            let seen = Set(found.map(\.id))
            // Jira refusing the text (400) finds nothing; Jira not answering is thrown.
            var text: [JiraIssue] = []
            do { text = try await client.search(jql: "text ~ \"\(escaped)*\" ORDER BY updated DESC", maxResults: 20, limit: 20) } catch JiraError.validation {}
            found += text.filter { !seen.contains($0.id) }
        }
        let ctx = await store.context()
        let me = ctx.data.instances.first { $0.id == instanceId }?.accountId
        let cache = Dictionary(ctx.data.issues.filter { $0.instanceId == instanceId }.map { ($0.issueId, $0) }, uniquingKeysWith: { a, _ in a })
        var c = Changes()
        var out: [Issue] = []
        for ji in found {
            let known = cache[ji.id]
            var x = known ?? Issue(instanceId: instanceId, issueId: ji.id, key: ji.key, summary: ji.summary)
            update(&x, from: ji, me: me, now: now)
            x.sources.insert("search")
            if mine.contains(ji.id) { x.sources.insert("logged") }
            // Only what is new or really changed is saved (beta 2026-10-22: every pause in typing wrote the same
            // tasks again — a database write and a full recompute of the app while the user typed).
            if var k = known {
                k.fetchedAt = x.fetchedAt
                // Jira's millisecond time read back from the database can differ in the last bits of the double.
                if let a = k.updated, let b = x.updated, abs(a.timeIntervalSince(b)) < 0.001 { k.updated = b }
                if k == x { out.append(x); continue }
            }
            c.upsertIssues.append(x)
            out.append(x)
        }
        if !c.upsertIssues.isEmpty { try await store.apply(c) }
        return out
    }

    /// Text inside a JQL "…" literal: backslash first, then quotes; line breaks become spaces.
    static func jqlString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: Instance succession (§9.11)

    public struct SuccessionPreview: Sendable {
        public var matched: [(groupId: UUID, worklog: JiraWorklog, issueId: String)] = []
        public var unmatchedOld: Int = 0
        public var matchedSeconds: Seconds = 0
        /// Work never sent to the old site whose task is on the new one: it moves there and is sent from there
        /// (an archived site sends nothing, so left behind it would never reach Jira).
        public var unsent: [(entryId: UUID, issueId: String)] = []
        public var unsentSeconds: Seconds = 0
        /// Never-sent entries whose task isn't on the new site: they stay, the user picks another task.
        public var unsentStuck: Int = 0
        /// The new site's tasks the links point to, cached with the link.
        public var issues: [JiraIssue] = []
    }

    /// Entries on `instance` that are not in Jira and never may have been (no worklog, no create in doubt).
    static func neverSent(on instance: UUID, _ data: DataSnapshot) -> [TimeEntry] {
        let groups = Dictionary(data.groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return data.entries.filter { e in
            guard e.deletedAt == nil, e.kind == .work, e.instanceId == instance, e.issueId != nil else { return false }
            guard let gid = e.worklogGroupId, let g = groups[gid] else { return true }
            return g.remoteWorklogId == nil && !g.createOutcomeUnknown
        }
    }

    /// Matches the successor's worklogs to the predecessor's by (issue key, local date, duration, started ± 1 min),
    /// and finds the successor's task for each never-sent entry by its key.
    public func previewSuccession(successor: UUID, predecessor: UUID, from date: LocalDate) async throws -> SuccessionPreview {
        guard let client = await clientFor(successor) else { throw JiraError.unauthorized }
        let ctx = await store.context()
        // Only your own worklogs on the new site can stand for the old ones — never a colleague's.
        guard let me = ctx.data.instances.first(where: { $0.id == successor })?.accountId, !me.isEmpty else { throw JiraError.unauthorized }
        let oldIssues = Dictionary(ctx.data.issues.filter { $0.instanceId == predecessor }.map { ($0.issueId, $0) }, uniquingKeysWith: { a, _ in a })
        let oldGroups = ctx.data.groups.filter { $0.instanceId == predecessor && $0.remoteWorklogId != nil && $0.localDate < date && $0.deletedAt == nil }
        let unsent = Self.neverSent(on: predecessor, ctx.data)
        let sentKeys = Set(oldGroups.compactMap { oldIssues[$0.issueId]?.key }.filter(JiraIdentifier.isKey))
        let unsentKeys = Set(unsent.compactMap { $0.issueId.flatMap { oldIssues[$0]?.key } }.filter(JiraIdentifier.isKey))
        var preview = SuccessionPreview()
        var cloudByKey: [String: (String, [JiraWorklog])] = [:]
        func keyIn(_ keys: [String]) -> String { "key in (\(keys.map { "\"\(Self.jqlString($0))\"" }.joined(separator: ",")))" }
        /// Jira can refuse a whole list for one key it doesn't have (a project that came over renamed): then one by one.
        func find(_ keys: [String]) async throws -> [JiraIssue] {
            do { return try await client.search(jql: keyIn(keys)) } catch JiraError.validation(_) where keys.count > 1 {
                var out: [JiraIssue] = []
                for k in keys { out += (try? await client.search(jql: keyIn([k]))) ?? [] }
                return out
            }
        }
        for chunk in Array(sentKeys.union(unsentKeys)).sorted().chunked(50) {
            let found = try await find(chunk)
            for ji in found {
                // Worklogs only where there are sent ones to match.
                let ws = sentKeys.contains(ji.key) ? try await client.worklogs(issueId: ji.id).filter { $0.authorId == me } : []
                cloudByKey[ji.key] = (ji.id, ws)
                preview.issues.append(ji)
            }
        }
        // Cloud keys have no underscore (OPS_DESK-12 → OPSDESK-12): the renamed task counts when its summary is the same.
        let oldByKey = Dictionary(oldIssues.values.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var renamed: [String: String] = [:]   // cloud key → old key
        for k in sentKeys.union(unsentKeys) where cloudByKey[k] == nil {
            if let ck = SuccessionHeal.cloudIssueKey(k) { renamed[ck] = k }
        }
        for chunk in Array(renamed.keys).sorted().chunked(50) {
            let found = try await find(chunk)
            for ji in found {
                guard let old = renamed[ji.key], SuccessionHeal.same(ji.summary, oldByKey[old]?.summary) else { continue }
                let ws = sentKeys.contains(old) ? try await client.worklogs(issueId: ji.id).filter { $0.authorId == me } : []
                cloudByKey[old] = (ji.id, ws)
                preview.issues.append(ji)
            }
        }
        var used = Set<String>()
        for g in oldGroups {
            guard let key = oldIssues[g.issueId]?.key, let sent = g.lastSent, let (cid, ws) = cloudByKey[key] else { preview.unmatchedOld += 1; continue }
            if let w = ws.first(where: { !used.contains($0.id) && $0.timeSpentSeconds == sent.durationSeconds
                && abs($0.started.timeIntervalSince(sent.startedAt)) <= 60 && LocalDate($0.started, calendar: ctx.calendar) == g.localDate }) {
                used.insert(w.id)
                preview.matched.append((g.id, w, cid))
                preview.matchedSeconds += w.timeSpentSeconds
            } else {
                preview.unmatchedOld += 1
            }
        }
        for e in unsent {
            guard let key = e.issueId.flatMap({ oldIssues[$0]?.key }), let (cid, _) = cloudByKey[key] else { preview.unsentStuck += 1; continue }
            preview.unsent.append((e.id, cid))
            preview.unsentSeconds += Seconds(max(0, (e.end ?? ctx.ledger.now).timeIntervalSince(e.start)))
        }
        return preview
    }

    /// What "Undo link" needs to put back (§9.11).
    public struct SuccessionUndo: Codable, Sendable {
        public struct Link: Codable, Sendable {
            public let groupId: UUID
            public let issueId: String
            public let remoteWorklogId: String?
            public let remoteUpdated: Date?
        }
        public struct Moved: Codable, Sendable {
            public let entryId: UUID
            public let issueId: String
        }
        public let successor: UUID
        public let predecessor: UUID
        public let links: [Link]
        public let copiedRules: [UUID]
        /// Never-sent entries moved to the successor (optional: undo records saved before 2026-11-12 lack them).
        public var moved: [Moved]?
        /// Copies dropped so a worklog counts once: the successor's import of it, or the old one when that import was already edited.
        public var removedGroups: [WorklogGroup]?
        public var removedEntries: [TimeEntry]?
    }

    /// Re-links matched groups/entries to the successor, moves never-sent work there, copies project rules,
    /// archives the predecessor. A worklog the successor already imported is not kept twice.
    @discardableResult
    public func applySuccession(_ preview: SuccessionPreview, successor: UUID, predecessor: UUID, date: LocalDate) async throws -> SuccessionUndo {
        try await locked { try await applySuccessionLocked(preview, successor: successor, predecessor: predecessor, date: date) }
    }

    private func applySuccessionLocked(_ preview: SuccessionPreview, successor: UUID, predecessor: UUID, date: LocalDate) async throws -> SuccessionUndo {
        let ctx = await store.context()
        var c = Changes()
        var links: [SuccessionUndo.Link] = []
        var removedGroups: [WorklogGroup] = []
        var removedEntries: [TimeEntry] = []
        let groups = Dictionary(ctx.data.groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The successor's own copies, looked up now: an import may have run since the preview.
        let successorByRemote = Dictionary(ctx.data.groups.filter { $0.instanceId == successor && $0.deletedAt == nil && $0.remoteWorklogId != nil }
            .map { ($0.remoteWorklogId!, $0) }, uniquingKeysWith: { a, _ in a })
        func live(_ gid: UUID) -> [TimeEntry] { ctx.data.entries.filter { $0.worklogGroupId == gid && $0.deletedAt == nil } }
        for m in preview.matched {
            guard var g = groups[m.groupId], g.instanceId == predecessor else { continue }
            if let dup = successorByRemote[m.worklog.id] {
                let dupEntries = live(dup.id)
                if dup.kind == .imported && dup.syncState == .synced && dupEntries.allSatisfy({ $0.source == .imported }) {
                    // Untouched import of the same worklog: the old group (with your own entries) takes its place.
                    removedGroups.append(dup); removedEntries += dupEntries
                    c.deleteGroups.append(dup.id); c.deleteEntries += dupEntries.map(\.id)
                } else {
                    // Already edited on the new site: that one stands, the old copy goes.
                    let oldEntries = live(g.id)
                    removedGroups.append(g); removedEntries += oldEntries
                    c.deleteGroups.append(g.id); c.deleteEntries += oldEntries.map(\.id)
                    continue
                }
            }
            let oldIssue = g.issueId
            links.append(.init(groupId: g.id, issueId: g.issueId, remoteWorklogId: g.remoteWorklogId, remoteUpdated: g.remoteUpdated))
            g.instanceId = successor
            g.issueId = m.issueId
            g.remoteWorklogId = m.worklog.id
            g.remoteUpdated = m.worklog.updated
            c.upsertGroups.append(g)
            for var e in ctx.data.entries where e.worklogGroupId == g.id && e.issueId == oldIssue {
                e.instanceId = successor
                e.issueId = m.issueId
                c.upsertEntries.append(e)
            }
        }
        // Never-sent work follows its task; the store's reconcile puts it in the successor's group for that day.
        var moved: [SuccessionUndo.Moved] = []
        let entries = Dictionary(ctx.data.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let stillUnsent = Set(Self.neverSent(on: predecessor, ctx.data).map(\.id))
        for u in preview.unsent where stillUnsent.contains(u.entryId) {
            guard var e = entries[u.entryId], let old = e.issueId else { continue }
            moved.append(.init(entryId: e.id, issueId: old))
            e.instanceId = successor
            e.issueId = u.issueId
            c.upsertEntries.append(e)
        }
        // The tasks the links point to, so days show them before the next import.
        let me = ctx.data.instances.first { $0.id == successor }?.accountId
        let cache = Dictionary(ctx.data.issues.filter { $0.instanceId == successor }.map { ($0.issueId, $0) }, uniquingKeysWith: { a, _ in a })
        for ji in preview.issues {
            var x = cache[ji.id] ?? Issue(instanceId: successor, issueId: ji.id, key: ji.key, summary: ji.summary)
            update(&x, from: ji, me: me, now: ctx.ledger.now)
            c.upsertIssues.append(x)
        }
        let existing = Set(ctx.data.rules.filter { $0.instanceId == successor }.map(\.value))
        for r in ctx.data.rules where r.instanceId == predecessor && !existing.contains(r.value) {
            c.upsertRules.append(ProjectRule(projectId: r.projectId, instanceId: successor, value: r.value))
        }
        if var old = ctx.data.instances.first(where: { $0.id == predecessor }) {
            old.status = .archived
            c.upsertInstances.append(old)
        }
        if var new = ctx.data.instances.first(where: { $0.id == successor }) {
            new.successorOf = predecessor
            new.successionDate = date
            c.upsertInstances.append(new)
        }
        try await store.apply(c)
        return SuccessionUndo(successor: successor, predecessor: predecessor, links: links, copiedRules: c.upsertRules.map(\.id),
                              moved: moved, removedGroups: removedGroups, removedEntries: removedEntries)
    }

    /// "Undo link": linked worklogs go back to the older Jira, which becomes active again.
    public func undoSuccession(_ u: SuccessionUndo) async throws { try await locked { try await undoSuccessionLocked(u) } }

    private func undoSuccessionLocked(_ u: SuccessionUndo) async throws {
        let ctx = await store.context()
        var c = Changes()
        let groups = Dictionary(ctx.data.groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for l in u.links {
            guard var g = groups[l.groupId] else { continue }
            let newIssue = g.issueId
            g.instanceId = u.predecessor
            g.issueId = l.issueId
            g.remoteWorklogId = l.remoteWorklogId
            g.remoteUpdated = l.remoteUpdated
            c.upsertGroups.append(g)
            for var e in ctx.data.entries where e.worklogGroupId == g.id && e.issueId == newIssue {
                e.instanceId = u.predecessor
                e.issueId = l.issueId
                c.upsertEntries.append(e)
            }
        }
        // Moved work goes back only while it is still unsent — once in the new Jira it belongs there.
        let entries = Dictionary(ctx.data.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let unsentThere = Set(Self.neverSent(on: u.successor, ctx.data).map(\.id))
        for m in u.moved ?? [] where unsentThere.contains(m.entryId) {
            guard var e = entries[m.entryId] else { continue }
            e.instanceId = u.predecessor
            e.issueId = m.issueId
            c.upsertEntries.append(e)
        }
        c.upsertGroups += u.removedGroups ?? []
        c.upsertEntries += u.removedEntries ?? []
        c.deleteRules = u.copiedRules
        if var old = ctx.data.instances.first(where: { $0.id == u.predecessor }) { old.status = .active; c.upsertInstances.append(old) }
        if var new = ctx.data.instances.first(where: { $0.id == u.successor }) { new.successorOf = nil; new.successionDate = nil; c.upsertInstances.append(new) }
        try await store.apply(c)
    }
}

extension WorklogGroup {
    /// A create went out but Jira's answer never came (timeout, dropped connection, 5xx): `remoteVersion` holds
    /// what was sent. Before creating again the engine looks for that worklog in Jira and links it instead.
    public var createOutcomeUnknown: Bool { remoteWorklogId == nil && remoteVersion != nil }
}

/// A non-reentrant async mutex (FIFO).
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
