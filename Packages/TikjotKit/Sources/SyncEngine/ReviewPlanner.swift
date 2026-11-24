import Foundation
import JiraKit
import TikjotDomain
import TikjotPersistence

/// What the Review & send sheet shows (§9.8): "Needs you" (only blocking things), "Goes to Jira", "Also:".
public struct ReviewPlan: Sendable {
    public enum Action: String, Sendable { case create, update, delete }

    public enum Note: Hashable, Sendable {
        case updatesExisting
        case overEstimate(spent: Seconds, estimate: Seconds)
        case overlaps(Seconds)
        case closedIssue(String)
        case emptyComment
        case commentOverrideStale
        case rounded(raw: Seconds, value: Seconds)
    }

    public struct Item: Identifiable, Sendable {
        public var id: UUID { groupId }
        public let groupId: UUID
        public let action: Action
        public let date: LocalDate
        public let issue: IssueRef
        public let issueKey: String
        public let issueSummary: String
        public let projectId: UUID?
        public let raw: Seconds
        public let value: Seconds
        public let started: Date
        public let descriptions: [String]
        public let comment: String
        public let notes: [Note]
        /// For update/delete: what is in Jira now.
        public let previous: SentSnapshot?
    }

    public enum Blocker: Sendable {
        case noTask(TimeEntry)
        case failed(groupId: UUID, error: SyncErrorInfo, line: WorklogLine)
        case conflict(groupId: UUID, local: WorklogLine?, jira: SentSnapshot?)
        case remoteDeleted(groupId: UUID, line: WorklogLine?)
        case taskUnavailable(groupId: UUID, line: WorklogLine)
    }

    public struct NeedsYou: Identifiable, Sendable {
        public let id: UUID
        public let date: LocalDate
        public let blocker: Blocker
    }

    public var items: [Item] = []
    public var needsYou: [NeedsYou] = []
    /// Unchanged worklogs in scope (shown only in "Also:").
    public var unchangedCount = 0
    public var unchangedSeconds: Seconds = 0
    /// Workdays in scope with nothing tracked.
    public var emptyDays: [LocalDate] = []
    public var runningExcluded = false

    public var sendItems: [Item] { items }
    public var total: Seconds { items.filter { $0.action != .delete }.reduce(0) { $0 + $1.value } }
    public var deletions: [Item] { items.filter { $0.action == .delete } }
    public var roundingDelta: Seconds { items.filter { $0.action != .delete }.reduce(0) { $0 + ($1.value - $1.raw) } }
    public var isEmpty: Bool { items.isEmpty && needsYou.isEmpty }
}

public enum ReviewScope: Sendable, Hashable {
    case days([LocalDate])
    /// Only these worklog groups (Unsent selection, "Review & send <KEY>").
    case groups(Set<UUID>)
}

public enum ReviewPlanner {
    public static func plan(scope: ReviewScope, data: DataSnapshot, ledger: Ledger, lock: LockPolicy, retry: Set<UUID> = []) -> ReviewPlan {
        var plan = ReviewPlan()
        let issues = Dictionary(data.issues.map { (IssueRef(instanceId: $0.instanceId, issueId: $0.issueId), $0) }, uniquingKeysWith: { a, _ in a })
        let activeInstances = Set(data.instances.filter { $0.status != .archived && $0.deletedAt == nil }.map(\.id))
        let today = ledger.today

        let days: [LocalDate]
        let groupFilter: Set<UUID>?
        switch scope {
        case .days(let ds):
            days = ds.sorted()
            groupFilter = nil
        case .groups(let ids):
            groupFilter = ids
            days = Array(Set(data.groups.filter { ids.contains($0.id) }.map(\.localDate))).sorted()
        }

        for d in days where lock.canSend(d, today: today) {
            let lines = ledger.lines(on: d)
            if lines.isEmpty && ledger.calendar.fund(d) > 0 && d < today && groupFilter == nil {
                plan.emptyDays.append(d)
            }
            let overlaps = EntryOps.overlaps(ledger.workEntries(on: d), now: ledger.now)
            for line in lines {
                if let groupFilter {
                    guard let g = line.group, groupFilter.contains(g.id) else { continue }
                }
                if line.isNoIssue {
                    if groupFilter == nil, let e = line.entries.first, !e.isRunning {
                        plan.needsYou.append(.init(id: e.id, date: d, blocker: .noTask(e)))
                    }
                    continue
                }
                guard let issue = line.issue else { continue }
                guard activeInstances.contains(issue.instanceId) else {
                    // On a site that was replaced (archived): it can't go there, and skipping it quietly left the day
                    // "not in Jira" with nothing to send (beta 2026-11-16). Pick its task on the new site.
                    let archived = data.instances.contains { $0.id == issue.instanceId && $0.status == .archived && $0.deletedAt == nil }
                    if archived, !line.containsRunning, ledger.state(of: line, lock: lock) != .synced, let e = line.entries.first {
                        let id = line.group?.id ?? e.id
                        plan.needsYou.append(.init(id: id, date: d, blocker: .taskUnavailable(groupId: id, line: line)))
                    }
                    continue
                }
                var line = line
                if line.containsRunning {
                    plan.runningExcluded = true
                    // Only the running entry waits; the task's finished entries go now (§9.8).
                    let finished = line.entries.filter { !$0.isRunning }
                    guard !finished.isEmpty else { continue }
                    let raw = finished.reduce(0) { $0 + $1.duration(now: ledger.now) }
                    line = WorklogLine(key: line.key, date: line.date, entries: finished, issue: line.issue, projectId: line.projectId,
                                       group: line.group, raw: raw,
                                       value: line.group.flatMap { g in g.sentRaw == raw ? g.lastSent?.durationSeconds : nil } ?? ledger.rounding.apply(raw),
                                       started: finished[0].start, descriptions: WorklogLine.uniqueDescriptions(finished), containsRunning: false)
                }
                let state = ledger.state(of: line, lock: lock)
                let g = line.group
                let meta = issues[issue]
                if let g, meta?.availability != nil, meta?.availability != .ok, state != .synced {
                    plan.needsYou.append(.init(id: g.id, date: d, blocker: .taskUnavailable(groupId: g.id, line: line)))
                    continue
                }
                switch state {
                case .synced:
                    plan.unchangedCount += 1
                    plan.unchangedSeconds += line.value
                case .conflict:
                    if let g { plan.needsYou.append(.init(id: g.id, date: d, blocker: .conflict(groupId: g.id, local: line, jira: g.remoteVersion))) }
                case .remoteDeleted:
                    if let g { plan.needsYou.append(.init(id: g.id, date: d, blocker: .remoteDeleted(groupId: g.id, line: line))) }
                case .error where !(g.map { retry.contains($0.id) } ?? false):
                    if let g { plan.needsYou.append(.init(id: g.id, date: d, blocker: .failed(groupId: g.id, error: g.lastError ?? SyncErrorInfo(code: "?", message: ""), line: line))) }
                case .unsent, .modified, .error:
                    guard let g else { continue }
                    let action: ReviewPlan.Action = g.remoteWorklogId == nil ? .create : .update
                    var notes: [ReviewPlan.Note] = []
                    if action == .update { notes.append(.updatesExisting) }
                    if let m = meta {
                        if m.isDone { notes.append(.closedIssue(m.statusName ?? "Done")) }
                        if let est = m.originalEstimateSeconds, est > 0 {
                            let spent = (m.timeSpentSeconds ?? 0) + line.value - (g.lastSent?.durationSeconds ?? 0)
                            if spent > est { notes.append(.overEstimate(spent: spent, estimate: est)) }
                        }
                    }
                    let ids = Set(line.entries.map(\.id))
                    let ov = overlaps.filter { ids.contains($0.a) || ids.contains($0.b) }.reduce(0) { $0 + $1.seconds }
                    if ov > 0 { notes.append(.overlaps(ov)) }
                    if line.comment.isEmpty { notes.append(.emptyComment) }
                    if g.commentOverrideStale { notes.append(.commentOverrideStale) }
                    if line.raw != line.value { notes.append(.rounded(raw: line.raw, value: line.value)) }
                    plan.items.append(.init(groupId: g.id, action: action, date: d, issue: issue,
                                            issueKey: meta?.key ?? issue.issueId, issueSummary: meta?.summary ?? "",
                                            projectId: line.projectId, raw: line.raw, value: line.value, started: line.started,
                                            descriptions: line.descriptions, comment: line.comment, notes: notes, previous: g.lastSent))
                default:
                    break
                }
            }
            // Deletions: groups in Jira whose entries were removed here.
            for g in ledger.groups(on: d) where g.syncState == .pendingDelete && activeInstances.contains(g.instanceId) {
                if let groupFilter, !groupFilter.contains(g.id) { continue }
                let meta = issues[g.issueRef]
                plan.items.append(.init(groupId: g.id, action: .delete, date: d, issue: g.issueRef,
                                        issueKey: meta?.key ?? g.issueId, issueSummary: meta?.summary ?? "",
                                        projectId: nil, raw: 0, value: 0, started: g.lastSent?.startedAt ?? d.start(in: ledger.timeCalendar),
                                        descriptions: [], comment: "", notes: [], previous: g.lastSent))
            }
            for g in ledger.groups(on: d) where g.syncState == .remoteDeleted && !lines.contains(where: { $0.group?.id == g.id }) {
                plan.needsYou.append(.init(id: g.id, date: d, blocker: .remoteDeleted(groupId: g.id, line: nil)))
            }
        }
        plan.items.sort { ($0.date, $0.started) < ($1.date, $1.started) }
        return plan
    }
}
