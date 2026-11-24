import Foundation
import Testing
import JiraKit
import TikjotDomain
import TikjotPersistence
@testable import SyncEngine

@Suite struct SyncSafetyTests {
    func group(_ f: Fixture) async -> WorklogGroup? {
        await f.store.context().data.groups.first { $0.issueId == "1" }
    }

    @Test(arguments: [JiraKind.cloud, .dataCenter])
    func lostAnswerIsAdoptedNotDuplicated(kind: JiraKind) async throws {
        let f = try await Fixture.make(kind: kind)
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1", desc: "Retry logic")
        await f.server.loseNextResponse(method: "POST")
        let r1 = await f.engine.send(await f.plan(["2026-10-01"]).items)
        #expect(r1.stoppedBy == .outcomeUnknown)
        #expect(await f.server.myWorklogs().count == 1) // it did arrive
        #expect(await group(f)?.createOutcomeUnknown == true)
        // Still waiting to be sent (the automatic retry picks it up) …
        let plan = await f.plan(["2026-10-01"])
        #expect(plan.items.first?.action == .create)
        // … and sending again finds the worklog instead of creating a second one.
        let r2 = await f.engine.send(plan.items)
        #expect(r2.sentCount == 1)
        let ws = await f.server.myWorklogs()
        #expect(ws.count == 1)
        let g = try #require(await group(f))
        #expect(g.remoteWorklogId == ws[0].id)
        #expect(g.syncState == .synced && !g.createOutcomeUnknown)
        #expect(await f.plan(["2026-10-01"]).items.isEmpty)
        // Undo still takes it out.
        _ = await f.engine.undo(r2.undo)
        #expect(await f.server.myWorklogs().isEmpty)
    }

    @Test func lostAnswerThenEditedUpdatesTheAdoptedWorklog() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1", desc: "Retry logic")
        await f.server.loseNextResponse(method: "POST")
        _ = await f.engine.send(await f.plan(["2026-10-01"]).items)
        _ = try await f.add("2026-10-01 11:00", "2026-10-01 11:30", issue: "1", desc: "Retry logic")
        let plan = await f.plan(["2026-10-01"])
        #expect(plan.items.first?.value == 5400)
        #expect(await f.engine.send(plan.items).sentCount == 1)
        let ws = await f.server.myWorklogs()
        #expect(ws.count == 1)
        #expect(ws[0].seconds == 5400)
    }

    @Test func serverErrorOnCreateIsCheckedBeforeTheRetry() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        await f.server.inject(status: 500)
        let r = await f.engine.send(await f.plan(["2026-10-01"]).items)
        #expect(r.failed.count == 1)
        #expect(await f.server.requestLog.filter { $0.hasPrefix("POST") && $0.contains("worklog") }.count == 1) // not repeated
        var g = try #require(await group(f))
        #expect(g.syncState == .error && g.createOutcomeUnknown)
        // Retry keeps the marker; nothing arrived, so one worklog is created.
        try await f.engine.clearError(groupId: g.id)
        #expect(await group(f)?.createOutcomeUnknown == true)
        await f.server.clearLog()
        #expect(await f.engine.send(await f.plan(["2026-10-01"]).items).sentCount == 1)
        #expect(await f.server.requestLog.contains { $0.hasPrefix("GET") && $0.hasSuffix("/worklog") }) // looked first
        #expect(await f.server.myWorklogs().count == 1)
        g = try #require(await group(f))
        #expect(!g.createOutcomeUnknown && g.remoteWorklogId != nil)
    }

    @Test func definiteRefusalClearsTheMarker() async throws {
        let f = try await Fixture.make()
        await f.server.setRejectWorklogs(issueId: "1", message: "Issue is closed.")
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        _ = await f.engine.send(await f.plan(["2026-10-01"]).items)
        let g = try #require(await group(f))
        #expect(g.syncState == .error && !g.createOutcomeUnknown)
    }

    @Test func refreshLinksALostCreateInsteadOfImportingIt() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1", desc: "Retry logic")
        await f.server.loseNextResponse(method: "POST")
        _ = await f.engine.send(await f.plan(["2026-10-01"]).items)
        let report = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-02 18:01"))
        #expect(report.imported == 0)
        let ctx = await f.store.context()
        #expect(ctx.data.groups.count == 1)
        #expect(ctx.data.groups[0].remoteWorklogId == (await f.server.myWorklogs()[0].id))
        #expect(ctx.ledger.worked(LocalDate("2026-10-01")!) == 3600)
        #expect(await f.plan(["2026-10-01"]).items.isEmpty)
    }

    @Test func overlappingSendsCreateOnce() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        _ = try await f.add("2026-10-01 10:00", "2026-10-01 11:00", issue: "2")
        let items = await f.plan(["2026-10-01"]).items
        async let a = f.engine.send(items)
        async let b = f.engine.send(items)
        _ = await (a, b)
        #expect(await f.server.myWorklogs().count == 2)
        // A stale plan (made before the first send) doesn't create again either.
        _ = await f.engine.send(items)
        #expect(await f.server.myWorklogs().count == 2)
    }

    @Test func failedUndoKeepsTheLink() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        let report = await f.engine.send(await f.plan(["2026-10-01"]).items)
        await f.server.inject(status: 500)
        #expect(await f.engine.undo(report.undo) == 0)
        #expect(await f.server.myWorklogs().count == 1)
        let g = try #require(await group(f))
        #expect(g.remoteWorklogId != nil && g.syncState == .synced)
        #expect(await f.plan(["2026-10-01"]).items.isEmpty) // nothing re-created
    }

    @Test func colleaguesWorklogIsNeverChanged() async throws {
        let f = try await Fixture.make()
        let wid = await f.server.addWorklog(issueId: "1", author: "colleague", started: t("2026-10-01 09:00"), seconds: 3600)
        // A group wrongly linked to that worklog (e.g. old data), changed here.
        let g = WorklogGroup(instanceId: f.instance.id, issueId: "1", localDate: LocalDate("2026-10-01")!, remoteWorklogId: wid,
                             lastSent: SentSnapshot(startedAt: t("2026-10-01 09:00"), durationSeconds: 3600, comment: ""), sentRaw: 3600, syncState: .synced)
        var c = Changes(); c.upsertGroups = [g]
        try await f.store.apply(c)
        let e = TimeEntry(start: t("2026-10-01 09:00"), end: t("2026-10-01 11:00"), instanceId: f.instance.id, issueId: "1",
                          projectId: f.project.id, description: "", worklogGroupId: g.id)
        c = Changes(); c.upsertEntries = [e]
        try await f.store.apply(c)
        let plan = await f.plan(["2026-10-01"])
        #expect(plan.items.first?.action == .update)
        await f.server.clearLog()
        let r = await f.engine.send(plan.items)
        #expect(r.failed.count == 1)
        #expect(await !f.server.requestLog.contains { $0.hasPrefix("PUT") }) // refused before writing
        #expect(await f.server.worklogs[wid]?.seconds == 3600)
    }

    @Test func successionIgnoresColleaguesWorklogs() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        _ = await f.engine.send(await f.plan(["2026-10-01"]).items)
        let cloud = MockJiraServer(kind: .cloud, clock: { t("2026-10-02 18:00") })
        await cloud.add(.init(id: "9001", key: "ABC-1", summary: "Payment gateway retry"))
        await cloud.addWorklog(issueId: "9001", author: "colleague", started: t("2026-10-01 09:00"), seconds: 3600)
        let newInst = JiraInstance(name: "Cloud 2", kind: .cloud, baseURL: URL(string: "https://new.atlassian.net")!, authMethod: .cloudApiToken,
                                   login: "me", accountId: "me", historyStartDate: LocalDate("2026-09-01"))
        var c = Changes(); c.upsertInstances = [newInst]
        try await f.store.apply(c)
        try await f.engine.refreshIssues(instanceId: f.instance.id, issueIds: ["1"])
        let newClient = JiraClient(site: JiraSite(kind: .cloud, baseURL: newInst.baseURL, credentials: .init(method: .cloudApiToken, login: "me", secret: "secret")), transport: cloud)
        let engine = SyncEngine(store: f.store, clientFor: { _ in newClient })
        let preview = try await engine.previewSuccession(successor: newInst.id, predecessor: f.instance.id, from: LocalDate("2026-10-02")!)
        #expect(preview.matched.isEmpty)
    }

    @Test func noAccountIdNoSync() async throws {
        let f = try await Fixture.make()
        var inst = f.instance
        inst.accountId = nil
        var c = Changes(); c.upsertInstances = [inst]
        try await f.store.apply(c)
        await #expect(throws: JiraError.unauthorized) { try await f.engine.refresh(instanceId: inst.id) }
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        let r = await f.engine.send(await f.plan(["2026-10-01"]).items)
        #expect(r.stoppedBy == .unauthorized)
        #expect(await f.server.myWorklogs().isEmpty)
    }

    @Test func jqlStringsAreEscaped() {
        #expect(SyncEngine.jqlString(#"a"b"#) == #"a\"b"#)
        #expect(SyncEngine.jqlString(#"a\"#) == #"a\\"#)
        #expect(SyncEngine.jqlString(#"x\" OR project = SECRET"#) == #"x\\\" OR project = SECRET"#)
    }
}
