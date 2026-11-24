import Foundation
import Testing
import TikjotDomain
@testable import TikjotPersistence

@Suite struct InstanceMergeTests {
    @Test func siteKeyIncludesSchemeAndPort() {
        func k(_ s: String) -> String { InstanceMerge.siteKey(URL(string: s)!) }
        #expect(k("https://JIRA.example.com/") == k("https://jira.example.com"))
        #expect(k("https://jira.example.com:443/jira") == k("https://jira.example.com/jira/"))
        #expect(k("http://jira.example.com") != k("https://jira.example.com"))
        #expect(k("https://jira.example.com:8443") != k("https://jira.example.com"))
        #expect(k("https://jira.example.com/jira") != k("https://jira.example.com"))
    }

    @Test func twinConnectionIsMergedWithoutDuplicateWorklogs() throws {
        let old = JiraInstance(name: "Jira", kind: .dataCenter, baseURL: URL(string: "https://jira.example.com")!, authMethod: .pat,
                               login: "me", accountId: "me", createdAt: Date(timeIntervalSince1970: 1_000))
        let twin = JiraInstance(name: "Jira", kind: .dataCenter, baseURL: URL(string: "https://JIRA.example.com/")!, authMethod: .pat,
                                login: "me", accountId: "me", tokenExpires: LocalDate("2027-09-01"), createdAt: Date(timeIntervalSince1970: 2_000))
        let day = LocalDate("2026-09-21")!
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let g1 = WorklogGroup(instanceId: old.id, issueId: "1", localDate: day, kind: .imported, remoteWorklogId: "w1", syncState: .synced)
        let g1twin = WorklogGroup(instanceId: twin.id, issueId: "1", localDate: day, kind: .imported, remoteWorklogId: "w1", syncState: .synced)
        let g2twin = WorklogGroup(instanceId: twin.id, issueId: "2", localDate: day, kind: .imported, remoteWorklogId: "w2", syncState: .synced)
        let e1 = TimeEntry(start: t, end: t + 3600, instanceId: old.id, issueId: "1", description: "", worklogGroupId: g1.id)
        let e1twin = TimeEntry(start: t, end: t + 3600, instanceId: twin.id, issueId: "1", description: "", worklogGroupId: g1twin.id)
        let e2twin = TimeEntry(start: t + 3600, end: t + 7200, instanceId: twin.id, issueId: "2", description: "", worklogGroupId: g2twin.id)

        var data = DataSnapshot()
        data.instances = [old, twin]
        data.groups = [g1, g1twin, g2twin]
        data.entries = [e1, e1twin, e2twin]
        data.issues = [Issue(instanceId: old.id, issueId: "1", key: "A-1", summary: ""), Issue(instanceId: twin.id, issueId: "1", key: "A-1", summary: ""),
                       Issue(instanceId: twin.id, issueId: "2", key: "A-2", summary: "")]

        let r = InstanceMerge.mergeDuplicates(in: data)
        #expect(r.merged.count == 1 && r.merged[0].kept == old.id)
        data.apply(r.changes)
        #expect(data.instances.map(\.id) == [old.id])
        #expect(data.instances.first?.tokenExpires == LocalDate("2027-09-01")) // the twin's (newest) token is kept, with its expiry
        #expect(Set(data.groups.map(\.remoteWorklogId)) == ["w1", "w2"])
        #expect(data.groups.allSatisfy { $0.instanceId == old.id })
        #expect(data.entries.count == 2 && data.entries.allSatisfy { $0.instanceId == old.id })
        #expect(Set(data.issues.map(\.issueId)) == ["1", "2"] && data.issues.allSatisfy { $0.instanceId == old.id })
        #expect(InstanceMerge.mergeDuplicates(in: data).merged.isEmpty)

        // Same through the database (deleting the twin also removes its cached issues).
        let db = try AppDatabase()
        var seed = Changes()
        seed.upsertInstances = [old, twin]; seed.upsertGroups = [g1, g1twin, g2twin]; seed.upsertEntries = [e1, e1twin, e2twin]
        seed.upsertIssues = [Issue(instanceId: old.id, issueId: "1", key: "A-1", summary: ""), Issue(instanceId: twin.id, issueId: "1", key: "A-1", summary: ""),
                             Issue(instanceId: twin.id, issueId: "2", key: "A-2", summary: "")]
        try db.apply(seed)
        try db.apply(InstanceMerge.mergeDuplicates(in: try db.load()).changes)
        let after = try db.load()
        #expect(after.instances.count == 1 && after.groups.count == 2 && after.entries.count == 2)
        #expect(after.issues.count == 2 && after.issues.allSatisfy { $0.instanceId == old.id })
    }

    @Test func connectFindsTheSameSite() {
        var data = DataSnapshot()
        let i = JiraInstance(name: "Jira", kind: .cloud, baseURL: URL(string: "https://acme.atlassian.net/")!, authMethod: .cloudApiToken, login: "a", accountId: "x")
        data.instances = [i]
        #expect(InstanceMerge.findSame(in: data, baseURL: URL(string: "https://acme.atlassian.net")!, accountId: "x")?.id == i.id)
        #expect(InstanceMerge.findSame(in: data, baseURL: URL(string: "https://acme.atlassian.net")!, accountId: "y") == nil)
    }
}
