import Foundation
import JiraKit
import SyncEngine
import TikjotDomain
import TikjotPersistence

/// Builds a `JiraClient` per instance from the Keychain (or the mock server in demo mode).
final class JiraConnections: @unchecked Sendable {
    let mock: MockJiraServer?
    private let cache = ClientCache()
    /// Set by the model: looks up an instance's connection details.
    @MainActor weak var model: AppModel?
    /// The automatic send retry (§9.8): at most one, replaced (not stacked) when sending stops again.
    @MainActor var sendRetry: Task<Void, Never>?
    /// Worklog groups the pending retry will send (re-planned from current data when it runs).
    @MainActor var retryGroups: Set<UUID> = []
    @MainActor var retryAttempt = 0

    init(mock: MockJiraServer? = nil) { self.mock = mock }

    func client(for instanceId: UUID) async -> JiraClient? {
        if let c = cache.get(instanceId) { return c }
        let generation = cache.currentGeneration
        guard let info = await MainActor.run(body: { self.model?.data.instances.first { $0.id == instanceId } }) else { return nil }
        let secret: String
        if mock != nil {
            secret = "demo"
        } else {
            guard let d = Keychain.read(Keychain.jiraAccount(instanceId)), let s = String(data: d, encoding: .utf8) else { return nil }
            secret = s
        }
        let client = makeClient(kind: info.kind, baseURL: info.baseURL, method: info.authMethod, login: info.login, secret: secret)
        cache.set(instanceId, client, generation: generation)
        return client
    }

    func makeClient(kind: JiraKind, baseURL: URL, method: JiraAuthMethod, login: String, secret: String) -> JiraClient {
        let site = JiraSite(kind: kind, baseURL: baseURL, credentials: JiraCredentials(method: method, login: login, secret: secret))
        if let mock { return JiraClient(site: site, transport: mock) }
        return JiraClient(site: site, onRateLimit: { secs in
            Task { @MainActor in AppDelegate.shared?.model?.rateLimitedFor = secs }
        })
    }

    /// Cloud or Data Center at this address, asked before signing in (nil: not reachable / doesn't say).
    func detectJiraKind(_ baseURL: URL) async -> JiraKind? {
        if let mock { return await JiraSite.detectKind(at: baseURL, transport: mock) }
        return await JiraSite.detectKind(at: baseURL)
    }

    func forget(_ instanceId: UUID) async { cache.remove(instanceId) }

    /// Drops every cached client at once (backup restored: tokens are gone, nothing may keep using an old one).
    func forgetAll() { cache.removeAll() }

    /// Synchronous so `forgetAll` takes effect before anything else runs.
    final class ClientCache: @unchecked Sendable {
        private let lock = NSLock()
        private var clients: [UUID: JiraClient] = [:]
        /// Bumped by `removeAll`, so a client built from a token read before it isn't cached afterwards.
        private var generation = 0
        var currentGeneration: Int { lock.withLock { generation } }
        func get(_ id: UUID) -> JiraClient? { lock.withLock { clients[id] } }
        func set(_ id: UUID, _ c: JiraClient, generation g: Int) { lock.withLock { if g == generation { clients[id] = c } } }
        func remove(_ id: UUID) { lock.withLock { clients[id] = nil } }
        func removeAll() { lock.withLock { clients = [:]; generation += 1 } }
    }
}

extension AppModel {
    // MARK: Connect (§9.1, onboarding step 4, Settings › Jira)

    struct ConnectResult {
        var instance: JiraInstance
        var user: JiraUser
    }

    /// Tests the connection with `/myself` and saves the instance + secret. A saved Cloud API token silently gets
    /// Atlassian's maximum, a year from today (correctable in Settings › Jira, decided 2026-10-06); other methods none.
    func connect(name: String, kind: JiraKind, baseURL: URL, method: JiraAuthMethod, login: String, secret: String,
                 historyStart: LocalDate, replacing existing: JiraInstance? = nil) async throws -> ConnectResult {
        let client = connections.makeClient(kind: kind, baseURL: baseURL, method: method, login: login, secret: secret)
        let me = try await client.testConnection()
        // Same site + same account again (e.g. onboarding run twice) → reconnect that one, never a twin that re-imports everything.
        let reuse = existing ?? InstanceMerge.findSame(in: data, baseURL: baseURL, accountId: me.id)
        var inst = reuse ?? JiraInstance(name: name, kind: kind, baseURL: baseURL, authMethod: method, login: login)
        inst.name = name
        inst.kind = kind
        inst.baseURL = baseURL
        inst.authMethod = method
        inst.login = login
        inst.accountId = me.id
        inst.displayName = me.displayName
        inst.jiraTimeZone = me.timeZone
        inst.status = .active
        markAllReachable()
        if reuse == nil { inst.historyStartDate = historyStart }
        if !demo { try Keychain.write(Data(secret.utf8), account: Keychain.jiraAccount(inst.id)) }
        await connections.forget(inst.id)
        var c = Changes()
        c.upsertInstances = [inst]
        applySilently(c)
        return ConnectResult(instance: inst, user: me)
    }

    /// Renew (signed-out banner, notification): Settings › Jira with the new-token band open under that site.
    func requestTokenRenewal(_ id: UUID) {
        renewTokenRequest = id
        AppDelegate.shared?.windows.showSettings(self, tab: .jira)
    }

    /// Repairs twin connections to the same Jira site + account (duplicate imported worklogs); the newest token is kept.
    func mergeDuplicateInstances() {
        let r = InstanceMerge.mergeDuplicates(in: data)
        guard !r.merged.isEmpty else { return }
        for m in r.merged {
            if !demo, let token = Keychain.read(Keychain.jiraAccount(m.removed)) {
                try? Keychain.write(token, account: Keychain.jiraAccount(m.kept))
            }
            Keychain.delete(Keychain.jiraAccount(m.removed))
        }
        Log.info("merged \(r.merged.count) duplicate Jira connection(s), dropped \(r.changes.deleteGroups.count) duplicate worklogs")
        applySilently(r.changes)
        Task { for m in r.merged { await connections.forget(m.removed); await connections.forget(m.kept) } }
    }

    /// Keeps history; sync off; can be reconnected (§9.12).
    func disconnect(_ inst: JiraInstance) async {
        Keychain.delete(Keychain.jiraAccount(inst.id))
        await connections.forget(inst.id)
        var x = inst
        x.status = .archived
        var c = Changes()
        c.upsertInstances = [x]
        applySilently(c)
        markReachable(inst.id)   // gone, so it no longer counts as "Jira can't be reached"
    }

    /// "Delete all data of this instance".
    func deleteAllData(of inst: JiraInstance) async {
        Keychain.delete(Keychain.jiraAccount(inst.id))
        await connections.forget(inst.id)
        var c = Changes()
        c.deleteInstances = [inst.id]
        c.deleteEntries = data.entries.filter { $0.instanceId == inst.id }.map(\.id)
        c.deleteGroups = data.groups.filter { $0.instanceId == inst.id }.map(\.id)
        c.deleteRules = data.rules.filter { $0.instanceId == inst.id }.map(\.id)
        applySilently(c)
        markReachable(inst.id)
    }

    // MARK: Refresh (§9.9)

    /// `only`: just these connections (the retries ask only the ones that didn't answer).
    func refreshAll(reason: String = "manual", only: Set<UUID>? = nil) async {
        let instances = activeInstances.filter { only?.contains($0.id) ?? true }
        guard !instances.isEmpty, refreshing == nil else { return }
        Log.info("refresh (\(reason))")
        lastRefreshStarted = Clock.now
        refreshing = (0, 1)
        defer { refreshing = nil }
        let conflictsBefore = conflictCount
        var moved: [(String, String)] = []
        for inst in instances {
            do {
                let report = try await engine.refresh(instanceId: inst.id, now: Clock.now) { p in
                    Task { @MainActor in
                        if case .issues(let d, let t) = p { self.refreshing = (d, max(t, 1)) }
                    }
                }
                moved += report.moved
                try? await engine.refreshAssigned(instanceId: inst.id)
                // Status / estimate / spent of tasks used in the last two weeks (§9.9), at most every 10 minutes.
                if Clock.now.timeIntervalSince(lastIssueRefresh[inst.id] ?? .distantPast) > 600 {
                    let since = Clock.now.addingTimeInterval(-14 * 86400)
                    let ids = Array(Set(data.entries.filter { $0.instanceId == inst.id && $0.start >= since }.compactMap(\.issueId)))
                    try? await engine.refreshIssues(instanceId: inst.id, issueIds: ids)
                    lastIssueRefresh[inst.id] = Clock.now
                }
                for s in data.suggestionSources where s.instanceId == inst.id { try? await engine.refreshSource(s) }
                markReachable(inst.id)
                noteUnmappedKeys(report.unmappedKeys, instanceId: inst.id)
            } catch let e as JiraError {
                handle(e, instance: inst)
            } catch {
                Log.error("refresh failed: \(type(of: error))")
            }
        }
        if let m = moved.first {
            showToast(String(localized: "\(m.0) moved — it's \(m.1) now"))
        }
        // Storyboard H: one muted tap when a conflict appears.
        if conflictCount > conflictsBefore { Sounds.play(.failed, enabled: data.settings.soundsEnabled) }
        now = Clock.now
    }

    func handle(_ e: JiraError, instance: JiraInstance) {
        switch e {
        case .offline, .hostNotFound, .noAnswer, .signInPage, .outcomeUnknown:
            // Behind the company sign-in (VPN off) behaves like being offline: calm banner, retry later.
            markUnreachable(instance.id, e)
        case .unauthorized:
            if lastRefreshError != e { lastRefreshError = e }
            if var x = data.instances.first(where: { $0.id == instance.id }), x.status != .authError {
                x.status = .authError
                var c = Changes()
                c.upsertInstances = [x]
                applySilently(c)
                NotificationService.shared.signedOut(instance: x)
            }
        default:
            if lastRefreshError != e { lastRefreshError = e }
            // Only the code: Jira's text can carry issue data.
            Log.error("jira error \(e.code)")
        }
    }

    /// A connection didn't answer. Beta 2026-10-14: a Data Center Jira behind a VPN that's off for days must stay
    /// quiet — the state (and the banner) changes only when it really changes, never off-and-on within one refresh
    /// because another connection answered.
    func markUnreachable(_ id: UUID, _ e: JiraError) {
        let first = unreachableInstances.isEmpty
        unreachableInstances.insert(id)
        if first { Log.info("jira unreachable (\(e.code))") }
        if !offline { offline = true }
        if lastRefreshError != e { lastRefreshError = e }
        scheduleOfflineRetry()
    }

    func markReachable(_ id: UUID) {
        unreachableInstances.remove(id)
        guard unreachableInstances.isEmpty else { return }
        if offline { Log.info("jira reachable again"); offline = false }
        if lastRefreshError != nil { lastRefreshError = nil }
    }

    /// All connections answer again (a new connection, onboarding).
    func markAllReachable() {
        for id in unreachableInstances { markReachable(id) }
        if offline { offline = false }
        if lastRefreshError != nil { lastRefreshError = nil }
    }

    /// Jira unreachable — a VPN still connecting after wake, or off for the day (on-premise Jira). Try again soon,
    /// then less and less often (10 s, 30 s, 1, 2, 5, 10, then every 15 min), asking only the connections that
    /// didn't answer; a network change (VPN on) tries at once anyway, so a long wait costs nothing.
    func scheduleOfflineRetry() {
        guard offlineRetry == nil, !demo else { return }
        offlineRetry = Task { @MainActor [weak self] in
            let delays: [UInt64] = [10, 30, 60, 120, 300, 600, 900]
            var attempt = 0
            while let self, self.offline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delays[min(attempt, delays.count - 1)] * 1_000_000_000)
                attempt += 1
                guard self.offline, !Task.isCancelled else { break }
                // Away from the Mac: no tries until you're back (`userIsBack`), which also restarts the schedule.
                if self.userAway() { self.jiraWaitsForYou = true; break }
                await self.refreshAll(reason: "retry", only: self.unreachableInstances)
            }
            self?.offlineRetry = nil
        }
    }

    /// The network changed (VPN connected, Wi-Fi back): while Jira is unreachable, one try once routes and DNS
    /// settle (3 s). Calls and VPN clients change the network in bursts — a burst makes one try, at most every 10 s
    /// (a VPN connecting a few seconds after launch is found within ~10 s); the retry schedule above keeps its pace.
    func networkChanged() {
        // A sleeping Mac's network comes and goes all night (dark wake) — those wait for you too.
        if offline && userAway() { jiraWaitsForYou = true; return }
        guard offline, !demo else { return }
        networkRetry?.cancel()
        let wait = max(3, 10 - Clock.now.timeIntervalSince(lastRefreshStarted))
        networkRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled, self.offline else { return }
            self.networkRetry = nil
            await self.refreshAll(reason: "network", only: self.unreachableInstances)
        }
    }

    /// Back at the Mac after being away (BackgroundServices): one refresh when a try waited for you or the last one is
    /// more than 5 minutes old, so what you see is current again. Returns whether it refreshed.
    func userIsBack() -> Bool {
        let waited = jiraWaitsForYou
        jiraWaitsForYou = false
        guard waited || Clock.now.timeIntervalSince(lastRefreshStarted) > 300 else { return false }
        return true
    }

    // MARK: Review & send (§9.8)

    func plan(_ scope: ReviewScope, retry: Set<UUID> = []) -> ReviewPlan {
        ReviewPlanner.plan(scope: scope, data: data, ledger: ledger, lock: lock, retry: retry)
    }

    func send(_ items: [ReviewPlan.Item], progress: @escaping @MainActor (SendProgress) -> Void) async -> SendReport {
        await performSend(items, background: false, progress: progress)
    }

    /// The one way worklogs go to Jira — the Send button and the automatic retry alike. The engine runs one
    /// send at a time and re-checks every group against stored data, so overlapping sends can't double a worklog.
    private func performSend(_ items: [ReviewPlan.Item], background: Bool, progress: (@MainActor (SendProgress) -> Void)? = nil) async -> SendReport {
        sendInProgress = true
        defer { sendInProgress = false }
        let report = await engine.send(items) { p in Task { @MainActor in progress?(p) } }
        if !background { lastSendReport = report }
        if let stop = report.stoppedBy {
            // The connection that stopped it — a 401 on one site must not sign out another.
            if let inst = data.instances.first(where: { $0.id == report.stoppedOn }) { handle(stop, instance: inst) }
            // Unreachable, or the answer got lost (the retry first looks in Jira for what may have arrived).
            if stop.isUnreachable || stop.isSignInPage || stop == .outcomeUnknown {
                connections.retryAttempt = background ? connections.retryAttempt + 1 : 0
                scheduleSendRetry(Set(items.map(\.groupId)))
            }
        } else {
            // Nothing stopped it: every connection it went to answered.
            for id in Set(items.map(\.issue.instanceId)) { markReachable(id) }
            connections.retryAttempt = 0
        }
        Log.info("sent \(report.sentCount), failed \(report.failed.count)\(background ? " (retry)" : "")")
        // A background retry that went through stays quiet (no "Sent to Jira" notification since the simplicity pass).
        if background { return report }
        if !report.failed.isEmpty, report.stoppedBy == nil {
            NotificationService.shared.sendFailed(count: report.failed.count)
            MenuBarController.shared?.setWarning(true)
        }
        // Storyboard H: whoosh + chime only when everything went through; one muted tap when something failed.
        if report.failed.isEmpty && report.stoppedBy == nil {
            if report.sentCount > 0 { Sounds.play(.sent, enabled: data.settings.soundsEnabled) }
        } else {
            Sounds.play(.failed, enabled: data.settings.soundsEnabled)
        }
        return report
    }

    /// Jira unreachable: retry in 1 min, then every 5 min (§9.8). One pending retry at most — a new stop
    /// replaces it and adds its groups; the retry re-plans them from current data when it runs.
    func scheduleSendRetry(_ groupIds: Set<UUID>) {
        connections.retryGroups.formUnion(groupIds)
        connections.sendRetry?.cancel()
        let delay: UInt64 = connections.retryAttempt == 0 ? 60 : 300
        connections.sendRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            // From here on this retry is running, not pending: nothing cancels it mid-request.
            let ids = self.connections.retryGroups
            self.connections.retryGroups = []
            self.connections.sendRetry = nil
            let fresh = self.plan(.groups(ids)).items
            guard !fresh.isEmpty else { return }
            _ = await self.performSend(fresh, background: true)
        }
    }

    func undoSend(_ report: SendReport) async {
        let n = report.undo.count
        toast = Toast(text: String(localized: "Taking worklogs back out of Jira…"), progress: "0 / \(n)")
        let done = await engine.undo(report.undo) { done, total in
            Task { @MainActor in self.toast?.progress = "\(done) / \(total)" }
        }
        if done < n {
            Log.error("undo: \(n - done) of \(n) steps failed")
            // One number per plural string (a catalog plural with two numbers is fiddly).
            showToast(String(localized: "Couldn't take \(n - done) worklogs back — they're still in Jira."))
        } else {
            showToast(String(localized: "Back out of Jira — nothing lost here"))
        }
    }

    /// Restoring a backup brings back connections, not their tokens: forget every token and cached client of the
    /// connections before and after the restore, so nothing keeps talking to Jira until the user signs in again.
    func forgetJiraTokens(_ instanceIds: Set<UUID>) {
        for id in instanceIds { Keychain.delete(Keychain.jiraAccount(id)) }
        connections.forgetAll()
    }

    // MARK: Conflicts

    func takeJira(_ groupId: UUID) async { try? await engine.takeJira(groupId: groupId) }
    func keepJira(_ groupId: UUID) async { try? await engine.keepJira(groupId: groupId) }
    func keepMine(_ groupId: UUID) async { try? await engine.keepMine(groupId: groupId) }
    func sendAgain(_ groupId: UUID) async { try? await engine.sendAgain(groupId: groupId) }
    func removeLocally(_ groupId: UUID) async { try? await engine.removeLocally(groupId: groupId) }
    func retry(_ groupId: UUID) async { try? await engine.clearError(groupId: groupId) }

    // MARK: Search

    /// `unreachable`: a Jira didn't answer — the picker says it shows saved tasks only (owner 2026-10-13: a new
    /// task "wasn't there" while the company sign-in was in the way).
    func searchJira(_ text: String) async -> (issues: [Issue], unreachable: Bool) {
        var out: [Issue] = []
        var unreachable = false
        for inst in activeInstances where inst.status == .active {
            do {
                out += try await engine.search(instanceId: inst.id, text: text)
            } catch let e as JiraError {
                unreachable = true
                handle(e, instance: inst)
            } catch {
                unreachable = true
            }
        }
        return (out, unreachable)
    }

    /// The picker opened: tasks saved more than 5 minutes ago are fetched again in the background, so a task
    /// created in Jira a moment ago shows up without typing.
    func refreshIfStale() {
        guard jiraConnected, !demo, Clock.now.timeIntervalSince(lastRefreshStarted) > 300 else { return }
        Task { await refreshAll(reason: "picker") }
    }
}
