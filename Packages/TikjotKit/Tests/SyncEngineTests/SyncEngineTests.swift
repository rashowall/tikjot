import Foundation
import Testing
import JiraKit
import TikjotDomain
import TikjotPersistence
@testable import SyncEngine

let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Bratislava")!
    return c
}()

func t(_ s: String) -> Date {
    let f = DateFormatter()
    f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}

/// A SyncStore over an in-memory database that reconciles after every write, like the app.
actor TestStore: SyncStore {
    let db: AppDatabase
    var now: Date

    init(now: Date) throws {
        db = try AppDatabase()
        self.now = now
    }

    func setNow(_ d: Date) { now = d }

    func context() async -> SyncContext {
        let data = try! db.load()
        let dc = DayCalendar(schedule: data.schedule.isEmpty ? .standard : WorkSchedule(periods: data.schedule), absences: data.absences)
        let ledger = Ledger(entries: data.entries, groups: data.groups, projects: data.projects, calendar: dc,
                            rounding: data.settings.rounding, timeCalendar: cal, now: now)
        return SyncContext(data: data, ledger: ledger, lock: LockPolicy(graceDays: data.settings.graceDays), calendar: cal)
    }

    /// How many writes reached the store.
    var applyCount = 0

    func apply(_ changes: Changes) async throws {
        applyCount += 1
        try db.apply(changes)
        let data = try db.load()
        let r = Reconciler.reconcile(data, calendar: cal, lock: LockPolicy(graceDays: data.settings.graceDays), today: LocalDate(now, calendar: cal))
        try db.apply(r)
    }
}

struct Fixture {
    let server: MockJiraServer
    let store: TestStore
    let engine: SyncEngine
    let instance: JiraInstance
    let project: Project

    static func make(kind: JiraKind = .cloud, now: String = "2026-10-02 18:00") async throws -> Fixture {
        let server = MockJiraServer(kind: kind, clock: { t("2026-10-02 18:00") })
        await server.add(.init(id: "1", key: "ABC-1", summary: "Payment gateway retry", assignee: "me", estimate: 3600))
        await server.add(.init(id: "2", key: "PMO-415", summary: "Steering committee prep"))
        let store = try TestStore(now: t(now))
        let instance = JiraInstance(name: "Cloud", kind: kind, baseURL: URL(string: "https://acme.atlassian.net")!,
                                    authMethod: .cloudApiToken, login: "me@acme.com", accountId: "me",
                                    historyStartDate: LocalDate("2026-09-01"))
        let project = Project(name: "Payments", color: "tangerine")
        var c = Changes()
        c.upsertInstances = [instance]
        c.upsertProjects = [project]
        c.upsertRules = [ProjectRule(projectId: project.id, instanceId: instance.id, value: "ABC"),
                         ProjectRule(projectId: project.id, instanceId: instance.id, value: "PMO")]
        try await store.apply(c)
        let site = JiraSite(kind: kind, baseURL: instance.baseURL, credentials: JiraCredentials(method: .cloudApiToken, login: "me", secret: "secret"))
        let client = JiraClient(site: site, transport: server, sleep: { _ in })
        let engine = SyncEngine(store: store, clientFor: { _ in client })
        return Fixture(server: server, store: store, engine: engine, instance: instance, project: project)
    }

    func add(_ from: String, _ to: String?, issue: String?, desc: String = "") async throws -> TimeEntry {
        let e = TimeEntry(start: t(from), end: to.map(t), instanceId: issue == nil ? nil : instance.id, issueId: issue, projectId: project.id, description: desc)
        var c = Changes(); c.upsertEntries = [e]
        try await store.apply(c)
        return e
    }

    func plan(_ days: [String]) async -> ReviewPlan {
        let ctx = await store.context()
        return ReviewPlanner.plan(scope: .days(days.map { LocalDate($0)! }), data: ctx.data, ledger: ctx.ledger, lock: ctx.lock)
    }
}

@Suite struct SyncEngineTests {
    @Test(arguments: [JiraKind.cloud, .dataCenter])
    func sendCreatesOneWorklogPerTaskAndDay(kind: JiraKind) async throws {
        let f = try await Fixture.make(kind: kind)
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 09:52", issue: "1", desc: "Retry logic")
        _ = try await f.add("2026-10-01 13:00", "2026-10-01 14:00", issue: "1", desc: "Review")
        _ = try await f.add("2026-10-01 10:00", "2026-10-01 10:30", issue: nil, desc: "No task")
        try await f.engine.refreshIssues(instanceId: f.instance.id, issueIds: ["1"])
        var plan = await f.plan(["2026-10-01"])
        #expect(plan.items.count == 1)
        #expect(plan.items[0].value == 110 * 60)
        #expect(plan.items[0].action == .create)
        #expect(plan.needsYou.count == 1) // no-task entry
        #expect(plan.items[0].notes.contains(.overEstimate(spent: 110 * 60, estimate: 3600)))

        let report = await f.engine.send(plan.items)
        #expect(report.sentCount == 1)
        let ws = await f.server.myWorklogs()
        #expect(ws.count == 1)
        #expect(ws[0].seconds == 110 * 60)
        #expect(ws[0].comment == "• Retry logic\n• Review")
        #expect(ws[0].started == t("2026-10-01 09:00"))

        // nothing left to send
        plan = await f.plan(["2026-10-01"])
        #expect(plan.items.isEmpty)
        #expect(plan.unchangedCount == 1)

        // edit → update
        _ = try await f.add("2026-10-01 15:00", "2026-10-01 15:30", issue: "1", desc: "Review")
        plan = await f.plan(["2026-10-01"])
        #expect(plan.items.first?.action == .update)
        _ = await f.engine.send(plan.items)
        #expect(await f.server.myWorklogs()[0].seconds == 140 * 60)

        // delete all entries → delete in Jira
        let ctx = await f.store.context()
        var c = Changes()
        c.deleteEntries = ctx.data.entries.filter { $0.issueId == "1" }.map(\.id)
        try await f.store.apply(c)
        plan = await f.plan(["2026-10-01"])
        #expect(plan.items.first?.action == .delete)
        _ = await f.engine.send(plan.items)
        #expect(await f.server.myWorklogs().isEmpty)
    }

    @Test func runningEntryIsExcluded() async throws {
        let f = try await Fixture.make(now: "2026-10-02 10:00")
        _ = try await f.add("2026-10-02 09:00", nil, issue: "1")
        var plan = await f.plan(["2026-10-02"])
        #expect(plan.items.isEmpty)
        #expect(plan.runningExcluded)
        // Finished entries of the same task go; the running one waits.
        _ = try await f.add("2026-10-02 07:00", "2026-10-02 08:00", issue: "1", desc: "Early")
        plan = await f.plan(["2026-10-02"])
        #expect(plan.items.count == 1)
        #expect(plan.items.first?.value == 3600)
        #expect(plan.items.first?.descriptions == ["Early"])
    }

    @Test func partialFailureAndRetry() async throws {
        let f = try await Fixture.make()
        await f.server.setRejectWorklogs(issueId: "2", message: "Issue is closed.")
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        _ = try await f.add("2026-10-01 10:00", "2026-10-01 11:00", issue: "2")
        let plan = await f.plan(["2026-10-01"])
        let report = await f.engine.send(plan.items)
        #expect(report.sentCount == 1)
        #expect(report.failed.count == 1)
        let plan2 = await f.plan(["2026-10-01"])
        guard case .failed(let gid, let err, _) = plan2.needsYou.first?.blocker else { Issue.record("expected failed"); return }
        #expect(err.message == "Issue is closed.")
        await f.server.setRejectWorklogs(issueId: "2", message: nil)
        try await f.engine.clearError(groupId: gid)
        let plan3 = await f.plan(["2026-10-01"])
        #expect(plan3.items.count == 1)
        #expect(await f.engine.send(plan3.items).sentCount == 1)
    }

    @Test func offlineStopsAndKeepsState() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        await f.server.setOffline(true)
        let report = await f.engine.send(await f.plan(["2026-10-01"]).items)
        #expect(report.stoppedBy == .offline)
        #expect(await f.plan(["2026-10-01"]).items.count == 1) // still waiting, not failed
        // Same for a company sign-in page (VPN off)
        await f.server.setOffline(false)
        await f.server.setSignInPage("<html><form action=\"https://login.microsoftonline.com/x\"></form></html>")
        let r2 = await f.engine.send(await f.plan(["2026-10-01"]).items)
        #expect(r2.stoppedBy?.isSignInPage == true)
        #expect(await f.plan(["2026-10-01"]).items.count == 1)
    }

    @Test func importAndConflicts() async throws {
        let f = try await Fixture.make()
        // Someone (another Mac) logged work → imported.
        let wid = await f.server.addWorklog(issueId: "2", started: t("2026-10-01 08:00"), seconds: 1800, comment: "• Agenda\n• Notes")
        await f.server.addWorklog(issueId: "2", author: "someone", started: t("2026-10-01 08:00"), seconds: 999)
        let r = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-02 18:00"))
        #expect(r.imported == 1)
        var ctx = await f.store.context()
        let imported = ctx.data.entries.first { $0.source == .imported }
        #expect(imported?.description == "Agenda; Notes")
        #expect(imported?.projectId == f.project.id)
        #expect(ctx.ledger.worked(LocalDate("2026-10-01")!) == 1800)
        #expect(ctx.ledger.inJira(LocalDate("2026-10-01")!) == 1800)

        // Sent worklog changed in Jira → conflict.
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1", desc: "Mine")
        _ = await f.engine.send(await f.plan(["2026-10-01"]).items)
        let mine = await f.server.myWorklogs().first { $0.issueId == "1" }!
        await f.server.setNow(t("2026-10-02 18:03"))
        await f.server.editWorklog(mine.id, seconds: 7200)
        let r2 = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-02 18:05"))
        #expect(r2.conflicts == 1)
        let plan = await f.plan(["2026-10-01"])
        guard case .conflict(let gid, _, let jira) = plan.needsYou.first(where: { if case .conflict = $0.blocker { return true }; return false })?.blocker else {
            Issue.record("expected conflict"); return
        }
        #expect(jira?.durationSeconds == 7200)
        try await f.engine.takeJira(groupId: gid)
        ctx = await f.store.context()
        #expect(ctx.ledger.worked(LocalDate("2026-10-01")!) == 1800 + 7200)

        // Imported worklog untouched here and edited in Jira → Jira wins silently.
        await f.server.setNow(t("2026-10-02 18:08"))
        await f.server.editWorklog(wid, seconds: 2400)
        let r3 = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-02 18:10"))
        #expect(r3.conflicts == 0)
        ctx = await f.store.context()
        #expect(ctx.ledger.worked(LocalDate("2026-10-01")!) == 2400 + 7200)

        // Deleted in Jira → remoteDeleted for a local-origin worklog.
        await f.server.setNow(t("2026-10-02 18:12"))
        await f.server.removeWorklog(mine.id)
        let r4 = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-02 18:15"))
        #expect(r4.remoteDeleted == 1)
        let plan2 = await f.plan(["2026-10-01"])
        #expect(plan2.needsYou.contains { if case .remoteDeleted = $0.blocker { return true }; return false })
    }

    @Test func importPreviewCountsTasksAndProjects() async throws {
        let f = try await Fixture.make()
        await f.server.addWorklog(issueId: "1", started: t("2026-09-10 09:00"), seconds: 3600)
        await f.server.addWorklog(issueId: "2", started: t("2026-09-11 09:00"), seconds: 3600)
        let p = try await f.engine.previewImport(instanceId: f.instance.id, from: LocalDate("2026-09-01")!)
        #expect(p.tasks == 2)
        #expect(Set(p.projects.keys) == ["ABC", "PMO"])
    }

    @Test func undoAfterSend() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        let report = await f.engine.send(await f.plan(["2026-10-01"]).items)
        #expect(await f.server.myWorklogs().count == 1)
        _ = await f.engine.undo(report.undo)
        #expect(await f.server.myWorklogs().isEmpty)
        #expect(await f.plan(["2026-10-01"]).items.first?.action == .create)
    }

    @Test func issueMovedKeepsIdentity() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        _ = await f.engine.send(await f.plan(["2026-10-01"]).items)
        _ = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-02 18:01"))
        await f.server.moveIssue(id: "1", newKey: "OPS-118")
        let r = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-02 18:10"))
        #expect(r.moved.first?.new == "OPS-118")
        let ctx = await f.store.context()
        #expect(ctx.data.issues.first { $0.issueId == "1" }?.key == "OPS-118")
        #expect(r.unmappedKeys["OPS"] != nil)
    }

    @Test func lockedDaysAreNotSent() async throws {
        let f = try await Fixture.make(now: "2026-10-10 10:00")
        _ = try await f.add("2026-09-29 09:00", "2026-09-29 10:00", issue: "1")
        let plan = await f.plan(["2026-09-29"])
        #expect(plan.items.isEmpty)
    }
}
