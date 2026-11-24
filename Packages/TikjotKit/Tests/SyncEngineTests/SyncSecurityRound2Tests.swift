import Foundation
import Testing
import JiraKit
import TikjotDomain
import TikjotPersistence
@testable import SyncEngine

@Suite struct SyncSecurityRound2Tests {
    /// Lost answer → the entry moves to another task before the retry → the worklog on the old task is
    /// found and deleted, one worklog remains (on the new task), nothing is orphaned.
    @Test(arguments: [JiraKind.cloud, .dataCenter])
    func lostCreateThenMovedToAnotherTask(kind: JiraKind) async throws {
        let f = try await Fixture.make(kind: kind)
        var e = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1", desc: "Retry logic")
        await f.server.loseNextResponse(method: "POST")
        let r1 = await f.engine.send(await f.plan(["2026-10-01"]).items)
        #expect(r1.stoppedBy == .outcomeUnknown)
        #expect(await f.server.myWorklogs().count == 1)

        e = try #require(await f.store.context().data.entries.first { $0.id == e.id })
        e.issueId = "2"
        var c = Changes(); c.upsertEntries = [e]
        try await f.store.apply(c)
        // The old group keeps its marker and waits to be deleted.
        let old = try #require(await f.store.context().data.groups.first { $0.issueId == "1" })
        #expect(old.syncState == .pendingDelete && old.createOutcomeUnknown)

        let plan = await f.plan(["2026-10-01"])
        #expect(Set(plan.items.map(\.action)) == [.create, .delete])
        let r2 = await f.engine.send(plan.items)
        #expect(r2.failed.isEmpty)
        let ws = await f.server.myWorklogs()
        #expect(ws.count == 1)
        #expect(ws.first?.issueId == "2")
        let groups = await f.store.context().data.groups
        #expect(groups.count == 1 && groups[0].issueId == "2" && groups[0].remoteWorklogId == ws.first?.id)
        #expect(await f.plan(["2026-10-01"]).items.isEmpty)
    }

    @Test func lostCreateThenDeletedLeavesNothingInJira() async throws {
        let f = try await Fixture.make()
        let e = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        await f.server.loseNextResponse(method: "POST")
        _ = await f.engine.send(await f.plan(["2026-10-01"]).items)
        var c = Changes(); c.deleteEntries = [e.id]
        try await f.store.apply(c)
        let plan = await f.plan(["2026-10-01"])
        #expect(plan.items.map(\.action) == [.delete])
        #expect(await f.engine.send(plan.items).failed.isEmpty)
        #expect(await f.server.myWorklogs().isEmpty)
        #expect(await f.store.context().data.groups.isEmpty)
    }

    /// Jira reads JQL dates in the profile's time zone: a worklog added in Jira just after the last refresh is
    /// found even when the profile is 9 hours behind the Mac.
    @Test func refreshDatesAreWrittenInTheJiraProfileTimeZone() async throws {
        let f = try await Fixture.make()
        await f.server.setTimeZone("America/Los_Angeles")
        var inst = f.instance
        inst.jiraTimeZone = "America/Los_Angeles"
        inst.syncCursor = t("2026-10-02 17:58")
        var c = Changes(); c.upsertInstances = [inst]
        try await f.store.apply(c)
        await f.server.addWorklog(issueId: "1", started: t("2026-10-01 09:00"), seconds: 3600) // updated 18:00
        let r = try await f.engine.refresh(instanceId: inst.id, now: t("2026-10-02 18:01"))
        #expect(r.imported == 1)
    }

    @Test func lostCreateThatNeverArrivedIsJustDropped() async throws {
        let f = try await Fixture.make()
        let e = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        await f.server.inject(status: 500)
        _ = await f.engine.send(await f.plan(["2026-10-01"]).items)
        let colleague = await f.server.addWorklog(issueId: "1", author: "colleague", started: t("2026-10-01 09:00"), seconds: 3600)
        var c = Changes(); c.deleteEntries = [e.id]
        try await f.store.apply(c)
        #expect(await f.engine.send(await f.plan(["2026-10-01"]).items).failed.isEmpty)
        #expect(await f.server.worklogs[colleague] != nil) // a colleague's look-alike is never touched
        #expect(await f.store.context().data.groups.isEmpty)
    }

    @Test func stopReportNamesTheConnection() async throws {
        let f = try await Fixture.make()
        var inst = f.instance
        inst.accountId = nil
        var c = Changes(); c.upsertInstances = [inst]
        try await f.store.apply(c)
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        let r = await f.engine.send(await f.plan(["2026-10-01"]).items)
        #expect(r.stoppedBy == .unauthorized && r.stoppedOn == inst.id)
        await f.server.setOffline(true)
        inst.accountId = "me"
        c = Changes(); c.upsertInstances = [inst]
        try await f.store.apply(c)
        let r2 = await f.engine.send(await f.plan(["2026-10-01"]).items)
        #expect(r2.stoppedBy == .offline && r2.stoppedOn == inst.id)
    }

    /// Delete all data / restore hold the writer lock: nothing is sent (or changed by a conflict action) meanwhile.
    @Test func pausedWritesWait() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        let items = await f.plan(["2026-10-01"]).items
        await f.engine.pauseWrites()
        let send = Task { await f.engine.send(items) }
        let gid = try #require(items.first?.groupId)
        let clear = Task { try await f.engine.clearError(groupId: gid) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await f.server.requestLog.isEmpty)
        // The data is replaced while paused: the waiting send finds nothing to send.
        var c = Changes(); c.deleteGroups = [gid]; c.deleteEntries = await f.store.context().data.entries.map(\.id)
        try await f.store.apply(c)
        await f.engine.resumeWrites()
        _ = await send.value
        try await clear.value
        #expect(await f.server.myWorklogs().isEmpty)
    }
}
