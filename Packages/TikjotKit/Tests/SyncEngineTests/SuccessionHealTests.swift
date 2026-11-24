import Foundation
import Testing
import JiraKit
import TikjotDomain
import TikjotPersistence
@testable import SyncEngine

/// Beta 2026-11-16 (testers): after the Data Center → Cloud link, projects came twice and a day stayed
/// "not in Jira" while Review had nothing to send.
@Suite struct SuccessionHealTests {
    let old = JiraInstance(name: "Jira", kind: .dataCenter, baseURL: URL(string: "https://jira.example.com")!, authMethod: .pat,
                           login: "me", accountId: "me", status: .archived)
    var new: JiraInstance {
        JiraInstance(name: "Cloud", kind: .cloud, baseURL: URL(string: "https://example.atlassian.net")!, authMethod: .cloudApiToken,
                     login: "me", accountId: "me", successorOf: old.id, successionDate: LocalDate("2026-11-16"))
    }

    @Test func projectsFollowTheirKeysAcrossTheLink() throws {
        let new = self.new
        var d = DataSnapshot()
        d.instances = [old, new]
        let intl = Project(name: "Internal activities", color: "green", billable: false)
        let intCloud = Project(name: "Internal activities", color: "orange")
        let pay = Project(name: "Payments platform", color: "blue")
        let payCloud = Project(name: "Payments platform", color: "green")
        let desk = Project(name: "Ops desk", color: "slate")
        let portal = Project(name: "Customer portal", color: "purple")
        let mine = Project(name: "Cloud experiments", color: "pink")   // made and named by you: stays
        d.projects = [intl, intCloud, pay, payCloud, desk, portal, mine]
        d.rules = [ProjectRule(projectId: intl.id, instanceId: old.id, value: "INT"),
                   ProjectRule(projectId: intCloud.id, instanceId: new.id, value: "INT"),
                   ProjectRule(projectId: pay.id, instanceId: old.id, value: "PAY_PLATFORM"),
                   ProjectRule(projectId: pay.id, instanceId: new.id, value: "PAY_PLATFORM"),   // copied by the link
                   ProjectRule(projectId: payCloud.id, instanceId: new.id, value: "PAYPLATFORM"),
                   ProjectRule(projectId: desk.id, instanceId: old.id, value: "OPS_DESK"),
                   ProjectRule(projectId: portal.id, instanceId: old.id, value: "PORTAL"),
                   ProjectRule(projectId: mine.id, instanceId: new.id, value: "PORTAL")]
        d.issues = [Issue(instanceId: old.id, issueId: "10", key: "PAY_PLATFORM-5", summary: "Release", projectName: "Payments platform"),
                    Issue(instanceId: new.id, issueId: "c10", key: "PAYPLATFORM-5", summary: "Release", projectName: "Payments platform"),
                    Issue(instanceId: old.id, issueId: "20", key: "OPS_DESK-7", summary: "Handover", projectName: "OPS_DESK"),
                    Issue(instanceId: new.id, issueId: "c20", key: "OPSDESK-7", summary: "Handover", projectName: "OPS_DESK"),
                    Issue(instanceId: new.id, issueId: "c30", key: "INT-1", summary: "Standup", projectName: "Internal activities")]
        let imported = TimeEntry(start: t("2026-11-10 09:00"), end: t("2026-11-10 10:00"), instanceId: new.id, issueId: "c30", projectId: intCloud.id)
        let today = TimeEntry(start: t("2026-11-16 09:00"), end: t("2026-11-16 11:00"), instanceId: old.id, issueId: "20", projectId: desk.id)
        d.entries = [imported, today]

        let c = SuccessionHeal.changes(d)
        #expect(Set(c.deleteProjects) == [intCloud.id, payCloud.id])
        d.apply(c)
        #expect(d.rules.first { $0.instanceId == new.id && $0.value == "INT" }?.projectId == intl.id)
        #expect(d.rules.first { $0.instanceId == new.id && $0.value == "PAYPLATFORM" }?.projectId == pay.id)
        #expect(d.rules.first { $0.instanceId == new.id && $0.value == "OPSDESK" }?.projectId == desk.id)
        // The copy of the old key on the new site, which has it only renamed, is gone.
        #expect(!d.rules.contains { $0.instanceId == new.id && $0.value == "PAY_PLATFORM" })
        #expect(d.rules.first { $0.instanceId == new.id && $0.value == "PORTAL" }?.projectId == mine.id)
        #expect(d.entries.first { $0.id == imported.id }?.projectId == intl.id)
        let moved = try #require(d.entries.first { $0.id == today.id })
        #expect(moved.instanceId == new.id && moved.issueId == "c20" && moved.projectId == desk.id)
        // Once in place, nothing more to do.
        #expect(SuccessionHeal.changes(d).isEmpty)
    }

    @Test func aRenamedKeyWithAnotherSummaryIsNotTheSameTask() {
        let new = self.new
        var d = DataSnapshot()
        d.instances = [old, new]
        let p = Project(name: "Ops desk", color: "slate")
        d.projects = [p]
        d.rules = [ProjectRule(projectId: p.id, instanceId: old.id, value: "OPS_DESK")]
        d.issues = [Issue(instanceId: old.id, issueId: "20", key: "OPS_DESK-7", summary: "Handover", projectName: "OPS_DESK"),
                    Issue(instanceId: new.id, issueId: "c20", key: "OPSDESK-7", summary: "Something else", projectName: "OPS_DESK")]
        let e = TimeEntry(start: t("2026-11-16 09:00"), end: t("2026-11-16 11:00"), instanceId: old.id, issueId: "20", projectId: p.id)
        d.entries = [e]
        d.apply(SuccessionHeal.changes(d))
        #expect(d.entries.first?.instanceId == old.id)
    }

    @Test func workLeftOnTheArchivedSiteNeedsYouInReview() async throws {
        let f = try await Fixture.make()
        _ = try await f.add("2026-10-02 09:00", "2026-10-02 10:00", issue: "2")
        try await f.engine.refreshIssues(instanceId: f.instance.id, issueIds: ["2"])
        var x = f.instance; x.status = .archived
        var c = Changes(); c.upsertInstances = [x]
        try await f.store.apply(c)
        let plan = await f.plan(["2026-10-02"])
        #expect(plan.items.isEmpty)
        #expect(plan.needsYou.count == 1)
        if case .taskUnavailable = plan.needsYou.first?.blocker {} else { Issue.record("expected taskUnavailable") }
    }

    @Test func previewFindsARenamedTaskBySummary() async throws {
        let f = try await Fixture.make()
        await f.server.add(.init(id: "3", key: "OPS_DESK-12", summary: "Handover desk"))
        let e = try await f.add("2026-10-02 09:00", "2026-10-02 10:00", issue: "3")
        try await f.engine.refreshIssues(instanceId: f.instance.id, issueIds: ["3"])
        let cloud = MockJiraServer(kind: .cloud, clock: { t("2026-10-02 18:00") })
        await cloud.add(.init(id: "9012", key: "OPSDESK-12", summary: "Handover desk"))
        let newInst = JiraInstance(name: "Cloud 2", kind: .cloud, baseURL: URL(string: "https://new.atlassian.net")!, authMethod: .cloudApiToken,
                                   login: "me", accountId: "me", historyStartDate: LocalDate("2026-09-01"))
        var c = Changes(); c.upsertInstances = [newInst]
        try await f.store.apply(c)
        let newClient = JiraClient(site: JiraSite(kind: .cloud, baseURL: newInst.baseURL, credentials: .init(method: .cloudApiToken, login: "me", secret: "secret")), transport: cloud)
        let engine = SyncEngine(store: f.store, clientFor: { _ in newClient })
        let preview = try await engine.previewSuccession(successor: newInst.id, predecessor: f.instance.id, from: LocalDate("2026-10-02")!)
        #expect(preview.unsent.map(\.entryId) == [e.id])
        #expect(preview.unsent.first?.issueId == "9012")
        #expect(preview.unsentStuck == 0)
    }
}
