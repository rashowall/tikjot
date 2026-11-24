import Foundation
import Testing
import JiraKit
import TikjotDomain
import TikjotPersistence
@testable import SyncEngine

@Suite struct SyncEdgeCaseTests {
    /// Beta 2026-10-22 (a tester): a description of several "- " lines came back from Data Center as a "• " list, so
    /// the sent day stayed "Update" forever. Whatever form Jira gives the same text back in, it counts as sent.
    @Test(arguments: [JiraKind.cloud, .dataCenter])
    func multiLineDescriptionStaysSent(kind: JiraKind) async throws {
        let f = try await Fixture.make(kind: kind)
        _ = try await f.add("2026-10-01 09:30", "2026-10-01 12:15", issue: "1", desc: "- Handover PRE/CEZ MapEngine\r\n- Pozvanka na meeting \n\n- Call")
        var plan = await f.plan(["2026-10-01"])
        #expect(plan.items.count == 1)
        _ = await f.engine.send(plan.items)
        plan = await f.plan(["2026-10-01"])
        #expect(plan.items.isEmpty)
        _ = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-02 18:00"))
        plan = await f.plan(["2026-10-01"])
        #expect(plan.items.isEmpty)
        let ctx = await f.store.context()
        #expect(ctx.ledger.dayStatus(LocalDate("2026-10-01")!, lock: ctx.lock) == .allInJira)
    }

    /// Beta 2026-10-25 (a tester): worklogs sent before one-point-per-line went as "• - a\n- b\n• c". They read "Update",
    /// and on a closed task the update failed and waited in Unsent for ever. The old form now counts as the same
    /// comment, and a failed update that matches Jira goes back to In Jira; a real change still doesn't.
    @Test func failedUpdateOfOldListFormIsInJiraAfterAll() async throws {
        let f = try await Fixture.make(kind: .dataCenter)
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1", desc: "- KC Upgrade\n- Rollback")
        _ = try await f.add("2026-10-01 10:00", "2026-10-01 11:00", issue: "1", desc: "Testing")
        _ = await f.engine.send(await f.plan(["2026-10-01"]).items)
        var ctx = await f.store.context()
        var g = try #require(ctx.data.groups.first { $0.remoteWorklogId != nil })
        g.lastSent?.comment = "• - KC Upgrade\n- Rollback\n• Testing"
        g.syncState = .error
        g.lastError = SyncErrorInfo(code: "http400", message: "You can not edit the issue as it is in a non-editable workflow state.")
        var c = Changes(); c.upsertGroups = [g]
        try await f.store.apply(c)
        ctx = await f.store.context()
        let healed = ctx.ledger.failedButInJira(lock: ctx.lock)
        #expect(healed.map(\.id) == [g.id])
        #expect(healed.first?.syncState == .synced && healed.first?.lastError == nil)
        // A changed word is still a change.
        g.lastSent?.comment = "• - KC Upgrade\n- Rollback\n• Testing docs"
        c = Changes(); c.upsertGroups = [g]
        try await f.store.apply(c)
        ctx = await f.store.context()
        #expect(ctx.ledger.failedButInJira(lock: ctx.lock).isEmpty)
    }

    /// A refused update (closed task) → Take Jira's: same time keeps the entries and takes only Jira's comment;
    /// a different time makes the entries what Jira has. Either way the line is In Jira and nothing is sent.
    @Test func keepJiraAfterARefusedUpdate() async throws {
        let f = try await Fixture.make(kind: .dataCenter)
        let a = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1", desc: "Rollback")
        _ = try await f.add("2026-10-01 10:00", "2026-10-01 11:00", issue: "1", desc: "Testing")
        _ = await f.engine.send(await f.plan(["2026-10-01"]).items)
        func refuse(_ edit: (inout TimeEntry) -> Void) async throws -> UUID {
            let ctx = await f.store.context()
            var e = try #require(ctx.data.entries.first { $0.id == a.id })
            edit(&e)
            var g = try #require(ctx.data.groups.first { $0.remoteWorklogId != nil })
            g.syncState = .error
            g.lastError = SyncErrorInfo(code: "http400", message: "non-editable workflow state")
            var c = Changes(); c.upsertEntries = [e]; c.upsertGroups = [g]
            try await f.store.apply(c)
            return g.id
        }
        // Only the description changed.
        var gid = try await refuse { $0.description = "Rollback + notes" }
        try await f.engine.keepJira(groupId: gid)
        var ctx = await f.store.context()
        #expect(ctx.data.entries.filter { $0.deletedAt == nil }.count == 2)
        #expect(ctx.data.entries.contains { $0.description == "Rollback + notes" })
        #expect(ctx.ledger.dayStatus(LocalDate("2026-10-01")!, lock: ctx.lock) == .allInJira)
        #expect(await f.plan(["2026-10-01"]).items.isEmpty)
        // The time changed too.
        gid = try await refuse { $0.end = t("2026-10-01 10:30") }
        try await f.engine.keepJira(groupId: gid)
        ctx = await f.store.context()
        #expect(ctx.ledger.worked(LocalDate("2026-10-01")!) == 7200)
        #expect(ctx.ledger.dayStatus(LocalDate("2026-10-01")!, lock: ctx.lock) == .allInJira)
        #expect(await f.server.myWorklogs().count == 1)
        #expect(ctx.data.entries.contains { $0.deletedAt == nil && $0.description == "Rollback\nTesting" })
    }

    @Test func editedImportedWorklogIsUpdatedNotDuplicated() async throws {
        let f = try await Fixture.make()
        await f.server.addWorklog(issueId: "2", started: t("2026-10-01 08:00"), seconds: 1800, comment: "Agenda")
        _ = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-02 18:00"))
        var ctx = await f.store.context()
        var e = try #require(ctx.data.entries.first { $0.source == .imported })
        e.end = t("2026-10-01 09:00") // 30m → 60m
        var c = Changes(); c.upsertEntries = [e]
        try await f.store.apply(c)
        let plan = await f.plan(["2026-10-01"])
        #expect(plan.items.count == 1)
        #expect(plan.items.first?.action == .update)
        #expect(plan.items.first?.value == 3600) // imported → minutes, not re-rounded
        _ = await f.engine.send(plan.items)
        let ws = await f.server.myWorklogs()
        #expect(ws.count == 1)
        #expect(ws[0].seconds == 3600)
        ctx = await f.store.context()
        #expect(ctx.ledger.worked(LocalDate("2026-10-01")!) == 3600)
    }

    @Test func importedEntryMovedToAnotherTaskDeletesOldWorklog() async throws {
        let f = try await Fixture.make()
        await f.server.addWorklog(issueId: "2", started: t("2026-10-01 08:00"), seconds: 1800, comment: "Agenda")
        _ = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-02 18:00"))
        var e = try #require(await f.store.context().data.entries.first { $0.source == .imported })
        e.issueId = "1"
        var c = Changes(); c.upsertEntries = [e]
        try await f.store.apply(c)
        let plan = await f.plan(["2026-10-01"])
        #expect(Set(plan.items.map(\.action)) == [.create, .delete])
        _ = await f.engine.send(plan.items)
        let ws = await f.server.myWorklogs()
        #expect(ws.count == 1)
        #expect(ws[0].issueId == "1")
    }

    /// Typing a project key ("abc") finds that project's tasks even if the key isn't in any summary.
    /// Beta 2026-10-22: the same results again write nothing (typing in the picker searched every pause).
    @Test func repeatedSearchWritesNothing() async throws {
        let f = try await Fixture.make()
        let first = try await f.engine.search(instanceId: f.instance.id, text: "Payment")
        #expect(!first.isEmpty)
        let before = await f.store.applyCount
        let again = try await f.engine.search(instanceId: f.instance.id, text: "Payment")
        #expect(again.map(\.id) == first.map(\.id))
        #expect(await f.store.applyCount == before)
    }

    @Test func searchByProjectKey() async throws {
        let f = try await Fixture.make()
        let found = try await f.engine.search(instanceId: f.instance.id, text: "abc")
        #expect(found.contains { $0.key == "ABC-1" })
        #expect(!found.contains { $0.key == "PMO-415" })
    }

    /// Jira not answering (offline, company sign-in) is thrown, so the picker can say it shows saved tasks only;
    /// an unknown key still just finds nothing.
    @Test func searchThrowsWhenJiraDoesntAnswer() async throws {
        let f = try await Fixture.make()
        #expect(try await f.engine.search(instanceId: f.instance.id, text: "NOPE-999").isEmpty)
        await f.server.setOffline(true)
        await #expect(throws: JiraError.self) { try await f.engine.search(instanceId: f.instance.id, text: "export") }
        await #expect(throws: JiraError.self) { try await f.engine.search(instanceId: f.instance.id, text: "ABC-1") }
        await f.server.setOffline(false)
        await f.server.setSignInPage("<html><form action=\"https://login.microsoftonline.com/x\"></form></html>")
        await #expect(throws: JiraError.self) { try await f.engine.search(instanceId: f.instance.id, text: "abc") }
    }

    /// The WEB case: a project key also brings the tasks you logged there, closed ones too — first, marked "logged".
    @Test func searchByProjectKeyBringsOwnClosedTasks() async throws {
        let f = try await Fixture.make()
        await f.server.add(.init(id: "142", key: "WEB-142", summary: "Daily analytics export", status: "Closed", statusCategory: "done", updated: t("2026-09-20 10:00")))
        await f.server.add(.init(id: "311", key: "WEB-311", summary: "Gateway logs cleanup", assignee: "colleague", updated: t("2026-10-02 09:00")))
        await f.server.add(.init(id: "298", key: "WEB-298", summary: "Retention policy draft", status: "Done", statusCategory: "done"))
        await f.server.addWorklog(issueId: "142", started: t("2026-09-15 09:00"), seconds: 3600)
        await f.server.addWorklog(issueId: "298", author: "jana", started: t("2026-09-16 09:00"), seconds: 3600)
        await f.server.clearLog()
        let found = try await f.engine.search(instanceId: f.instance.id, text: "WEB")
        #expect(found.first?.key == "WEB-142")
        #expect(found.contains { $0.key == "WEB-311" })
        // Closed with only someone else's worklogs: Jira's text search may still list it, but never as yours.
        #expect(found.first { $0.key == "WEB-298" }?.sources.contains("logged") != true)
        #expect(found.firstIndex { $0.key == "WEB-311" }! > found.firstIndex { $0.key == "WEB-142" }!)
        #expect(found.first { $0.key == "WEB-142" }?.sources.contains("logged") == true)
        #expect(found.first { $0.key == "WEB-311" }?.sources.contains("logged") == false)
        #expect(await f.server.jqlLog.first == "project = \"WEB\" AND worklogAuthor = currentUser() ORDER BY updated DESC")
    }

    @Test func deletedTaskDoesNotBreakRefresh() async throws {
        let f = try await Fixture.make()
        await f.server.addWorklog(issueId: "2", started: t("2026-10-01 08:00"), seconds: 1800, comment: "Agenda")
        await f.server.addWorklog(issueId: "1", started: t("2026-10-01 09:00"), seconds: 1800, comment: "Other")
        _ = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-02 18:00"))
        await f.server.removeIssue(id: "2")
        // Jira answers 400 for the whole "issueId in (…)" query now; refresh must carry on.
        _ = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-03 18:00"))
        try await f.engine.refreshIssues(instanceId: f.instance.id, issueIds: ["1", "2"], now: t("2026-10-03 18:00"))
        let issues = await f.store.context().data.issues
        #expect(issues.first { $0.issueId == "2" }?.availability == .deleted)
        #expect(issues.first { $0.issueId == "1" }?.availability != .deleted)
    }

    @Test func taskMissingFromSearchIndexStaysAvailable() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        _ = try await f.add("2026-10-01 10:00", "2026-10-01 11:00", issue: "2")
        try await f.engine.refreshIssues(instanceId: f.instance.id, issueIds: ["1", "2"], now: t("2026-10-03 18:00"))
        // Jira's search index lags behind: task 2 exists but search doesn't return it.
        await f.server.setUnindexed(["2"])
        try await f.engine.refreshIssues(instanceId: f.instance.id, issueIds: ["1", "2"], now: t("2026-10-03 18:10"))
        var issues = await f.store.context().data.issues
        #expect(issues.first { $0.issueId == "2" }?.availability == .ok)
        // A task marked unavailable earlier heals on the next refresh.
        var x = issues.first { $0.issueId == "2" }!
        x.availability = .deleted
        var c = Changes(); c.upsertIssues = [x]
        try await f.store.apply(c)
        try await f.engine.refreshIssues(instanceId: f.instance.id, issueIds: ["2"], now: t("2026-10-03 18:20"))
        issues = await f.store.context().data.issues
        #expect(issues.first { $0.issueId == "2" }?.availability == .ok)
    }

    @Test func roundingChangeKeepsSyncedValues() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 09:52", issue: "1")
        _ = await f.engine.send(await f.plan(["2026-10-01"]).items)
        var ctx = await f.store.context()
        #expect(ctx.ledger.worked(LocalDate("2026-10-01")!) == 50 * 60)
        var s = ctx.data.settings
        s.rounding = RoundingRule(unitMinutes: 30, mode: .up)
        var c = Changes(); c.settings = s
        try await f.store.apply(c)
        ctx = await f.store.context()
        #expect(ctx.ledger.worked(LocalDate("2026-10-01")!) == 50 * 60) // Jira value stands
        #expect(await f.plan(["2026-10-01"]).items.isEmpty)
    }

    @Test func lockedPeriodTakesJiraChangesSilently() async throws {
        let f = try await Fixture.make(now: "2026-10-02 18:00")
        _ = try await f.add("2026-09-01 09:00", "2026-09-01 10:00", issue: "1")
        _ = await f.engine.send(await f.plan(["2026-09-01"]).items)
        _ = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-02 18:01"))
        // Month moves on: September locks (grace 5 days).
        await f.store.setNow(t("2026-10-20 10:00"))
        let w = await f.server.myWorklogs()[0]
        await f.server.setNow(t("2026-10-20 09:00"))
        await f.server.editWorklog(w.id, seconds: 5400)
        let r = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-20 10:00"))
        #expect(r.lockedChanges == 1)
        #expect(r.conflicts == 0)
        let ctx = await f.store.context()
        let g = try #require(ctx.data.groups.first)
        #expect(g.changedInJiraWas == 3600)
        #expect(ctx.ledger.worked(LocalDate("2026-09-01")!) == 5400)
    }

    @Test func successionLinksCopiedWorklogs() async throws {
        let f = try await Fixture.make()
        // Old on-prem instance with a sent worklog.
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        _ = await f.engine.send(await f.plan(["2026-10-01"]).items)
        _ = try await f.engine.refresh(instanceId: f.instance.id, now: t("2026-10-02 18:01"))
        // New cloud instance with the copied issue and worklog.
        let cloud = MockJiraServer(kind: .cloud, clock: { t("2026-10-02 18:00") })
        await cloud.add(.init(id: "9001", key: "ABC-1", summary: "Payment gateway retry"))
        await cloud.addWorklog(issueId: "9001", started: t("2026-10-01 09:00"), seconds: 3600)
        let newInst = JiraInstance(name: "Cloud 2", kind: .cloud, baseURL: URL(string: "https://new.atlassian.net")!, authMethod: .cloudApiToken,
                                   login: "me", accountId: "me", historyStartDate: LocalDate("2026-09-01"))
        var c = Changes(); c.upsertInstances = [newInst]
        try await f.store.apply(c)
        let oldClient = JiraClient(site: JiraSite(kind: .cloud, baseURL: f.instance.baseURL, credentials: .init(method: .cloudApiToken, login: "me", secret: "secret")), transport: f.server)
        let newClient = JiraClient(site: JiraSite(kind: .cloud, baseURL: newInst.baseURL, credentials: .init(method: .cloudApiToken, login: "me", secret: "secret")), transport: cloud)
        let oldId = f.instance.id
        let engine = SyncEngine(store: f.store, clientFor: { $0 == oldId ? oldClient : newClient })
        let preview = try await engine.previewSuccession(successor: newInst.id, predecessor: f.instance.id, from: LocalDate("2026-10-02")!)
        #expect(preview.matched.count == 1)
        let undo = try await engine.applySuccession(preview, successor: newInst.id, predecessor: f.instance.id, date: LocalDate("2026-10-02")!)
        let r = try await engine.refresh(instanceId: newInst.id, now: t("2026-10-02 18:05"))
        #expect(r.imported == 0) // linked, not doubled
        var ctx = await f.store.context()
        #expect(ctx.ledger.worked(LocalDate("2026-10-01")!) == 3600)
        #expect(ctx.data.instances.first { $0.id == f.instance.id }?.status == .archived)
        try await engine.undoSuccession(undo)
        ctx = await f.store.context()
        #expect(ctx.data.instances.first { $0.id == f.instance.id }?.status == .active)
        #expect(ctx.data.groups.first?.instanceId == f.instance.id)
    }

    /// Cloud site for succession tests: ABC-1 copied as 9001 with the on-prem worklog of 1 Oct; PMO-415 not migrated.
    private func cloudSuccessor(_ f: Fixture) async throws -> (MockJiraServer, JiraInstance, SyncEngine) {
        let cloud = MockJiraServer(kind: .cloud, clock: { t("2026-10-02 18:00") })
        await cloud.add(.init(id: "9001", key: "ABC-1", summary: "Payment gateway retry"))
        await cloud.addWorklog(issueId: "9001", started: t("2026-10-01 09:00"), seconds: 3600)
        let newInst = JiraInstance(name: "Cloud 2", kind: .cloud, baseURL: URL(string: "https://new.atlassian.net")!, authMethod: .cloudApiToken,
                                   login: "me", accountId: "me", historyStartDate: LocalDate("2026-09-01"))
        var c = Changes(); c.upsertInstances = [newInst]
        try await f.store.apply(c)
        let oldClient = JiraClient(site: JiraSite(kind: .cloud, baseURL: f.instance.baseURL, credentials: .init(method: .cloudApiToken, login: "me", secret: "secret")), transport: f.server)
        let newClient = JiraClient(site: JiraSite(kind: .cloud, baseURL: newInst.baseURL, credentials: .init(method: .cloudApiToken, login: "me", secret: "secret")), transport: cloud)
        let oldId = f.instance.id
        return (cloud, newInst, SyncEngine(store: f.store, clientFor: { $0 == oldId ? oldClient : newClient }))
    }

    @Test func successionMovesNeverSentWorkToTheNewSite() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1")
        _ = await f.engine.send(await f.plan(["2026-10-01"]).items)
        // Logged after the old site went read-only: never sent there.
        let late = try await f.add("2026-10-02 09:00", "2026-10-02 10:30", issue: "1", desc: "After the freeze")
        let orphan = try await f.add("2026-10-02 11:00", "2026-10-02 11:30", issue: "2")
        try await f.engine.refreshIssues(instanceId: f.instance.id, issueIds: ["1", "2"])
        let (cloud, newInst, engine) = try await cloudSuccessor(f)
        let preview = try await engine.previewSuccession(successor: newInst.id, predecessor: f.instance.id, from: LocalDate("2026-10-02")!)
        #expect(preview.matched.count == 1)
        #expect(preview.unsent.map(\.entryId) == [late.id])
        #expect(preview.unsentSeconds == 5400)
        #expect(preview.unsentStuck == 1) // PMO-415 isn't on the new site
        let undo = try await engine.applySuccession(preview, successor: newInst.id, predecessor: f.instance.id, date: LocalDate("2026-10-02")!)
        var ctx = await f.store.context()
        let moved = ctx.data.entries.first { $0.id == late.id }
        #expect(moved?.instanceId == newInst.id && moved?.issueId == "9001")
        #expect(ctx.data.entries.first { $0.id == orphan.id }?.instanceId == f.instance.id)
        // It is sent to the new site, from Review as usual.
        let plan = ReviewPlanner.plan(scope: .days([LocalDate("2026-10-02")!]), data: ctx.data, ledger: ctx.ledger, lock: ctx.lock)
        #expect(plan.items.count == 1)
        _ = await engine.send(plan.items)
        #expect(await cloud.myWorklogs().count == 2)
        #expect(ctx.ledger.worked(LocalDate("2026-10-01")!) == 3600)
        // Undo leaves sent work where it went.
        try await engine.undoSuccession(undo)
        ctx = await f.store.context()
        #expect(ctx.data.entries.first { $0.id == late.id }?.instanceId == newInst.id)
    }

    @Test func undoSuccessionReturnsWorkStillUnsent() async throws {
        let f = try await Fixture.make()
        let late = try await f.add("2026-10-02 09:00", "2026-10-02 10:30", issue: "1")
        try await f.engine.refreshIssues(instanceId: f.instance.id, issueIds: ["1"])
        let (_, newInst, engine) = try await cloudSuccessor(f)
        let preview = try await engine.previewSuccession(successor: newInst.id, predecessor: f.instance.id, from: LocalDate("2026-10-02")!)
        let undo = try await engine.applySuccession(preview, successor: newInst.id, predecessor: f.instance.id, date: LocalDate("2026-10-02")!)
        try await engine.undoSuccession(undo)
        let e = await f.store.context().data.entries.first { $0.id == late.id }
        #expect(e?.instanceId == f.instance.id && e?.issueId == "1")
    }

    @Test func successionAfterTheNewSiteImportedTheCopiesCountsOnce() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-01 09:00", "2026-10-01 10:00", issue: "1", desc: "Retry")
        _ = await f.engine.send(await f.plan(["2026-10-01"]).items)
        try await f.engine.refreshIssues(instanceId: f.instance.id, issueIds: ["1"])
        let (_, newInst, engine) = try await cloudSuccessor(f)
        // Connected with history from September and imported before linking: the copy is counted twice for now.
        _ = try await engine.refresh(instanceId: newInst.id, now: t("2026-10-02 18:05"))
        var ctx = await f.store.context()
        #expect(ctx.ledger.worked(LocalDate("2026-10-01")!) == 7200)
        let preview = try await engine.previewSuccession(successor: newInst.id, predecessor: f.instance.id, from: LocalDate("2026-10-02")!)
        #expect(preview.matched.count == 1)
        let undo = try await engine.applySuccession(preview, successor: newInst.id, predecessor: f.instance.id, date: LocalDate("2026-10-02")!)
        ctx = await f.store.context()
        #expect(ctx.ledger.worked(LocalDate("2026-10-01")!) == 3600)
        let linked = ctx.data.groups.filter { $0.instanceId == newInst.id && $0.deletedAt == nil }
        #expect(linked.count == 1)
        #expect(ctx.data.entries.filter { $0.worklogGroupId == linked.first?.id }.first?.description == "Retry") // your own entry kept
        let r = try await engine.refresh(instanceId: newInst.id, now: t("2026-10-02 18:10"))
        #expect(r.imported == 0)
        // Undo puts both back as they were.
        try await engine.undoSuccession(undo)
        ctx = await f.store.context()
        #expect(ctx.data.groups.filter { $0.instanceId == newInst.id }.count == 1)
        #expect(ctx.data.groups.filter { $0.instanceId == f.instance.id }.count == 1)
    }
}
