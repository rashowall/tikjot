import Foundation
import Testing
import TikjotDomain
@testable import JiraKit

struct FixtureTransport: HTTPTransport {
    let file: String
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "Fixtures")!
        return (try Data(contentsOf: url), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

func site(_ kind: JiraKind, secret: String = "secret") -> JiraSite {
    JiraSite(kind: kind, baseURL: URL(string: kind == .cloud ? "https://acme.atlassian.net" : "https://jira.acme.com")!,
             credentials: JiraCredentials(method: kind == .cloud ? .cloudApiToken : .pat, login: "me@acme.com", secret: secret))
}

@Suite struct CommentTests {
    @Test func renderAndParseADF() {
        let text = CommentRenderer.plain(["Sprint review", "Release notes"])
        #expect(text == "• Sprint review\n• Release notes")
        let adf = CommentRenderer.adf(text)
        #expect(((adf["content"] as? [[String: Any]])?.first?["type"] as? String) == "bulletList")
        #expect(CommentRenderer.plain(fromADF: adf) == text)
        #expect(CommentRenderer.plain(fromADF: CommentRenderer.adf("One thing")) == "One thing")
        #expect(CommentRenderer.plain(fromADF: CommentRenderer.adf("")) == "")
    }

    @Test func wiki() {
        let text = "• A\n• B"
        #expect(CommentRenderer.wiki(text) == "* A\n* B")
        #expect(CommentRenderer.plain(fromWiki: "* A\n* B") == text)
        #expect(CommentRenderer.description(fromPlain: text) == "A; B")
    }

    @Test func jiraDates() {
        let d = JiraDate.parse("2026-10-01T09:15:00.000+0200")!
        #expect(JiraDate.format(d, timeZone: TimeZone(identifier: "Europe/Bratislava")!) == "2026-10-01T09:15:00.000+0200")
    }
}

@Suite struct FixtureParsingTests {
    @Test func cloudWorklogs() async throws {
        let c = JiraClient(site: site(.cloud), transport: FixtureTransport(file: "cloud-worklogs"))
        let ws = try await c.worklogs(issueId: "10010")
        #expect(ws.count == 2)
        #expect(ws[0].comment == "• Sprint review\n• Release notes")
        #expect(ws[0].timeSpentSeconds == 6900)
        #expect(ws[0].authorId == "5b10ac8d82e05b22cc7d4ef5")
    }

    @Test func dcSearch() async throws {
        let c = JiraClient(site: site(.dataCenter), transport: FixtureTransport(file: "dc-search"))
        let issues = try await c.search(jql: "key = PMO-415")
        #expect(issues.count == 1)
        let i = issues[0]
        #expect(i.key == "PMO-415")
        #expect(i.statusCategory == .done)
        #expect(i.parentSummary == "Steering 2026")
        #expect(i.assigneeId == "jdoe")
        #expect(i.originalEstimateSeconds == 28800)
        #expect(i.projectName == "Steering 2026")
    }
}

@Suite struct MockServerTests {
    @Test(arguments: [JiraKind.cloud, .dataCenter])
    func worklogLifecycle(kind: JiraKind) async throws {
        let server = MockJiraServer(kind: kind)
        await server.add(.init(id: "1", key: "ABC-1", summary: "Payment gateway retry", assignee: "me"))
        let client = JiraClient(site: site(kind), transport: server)
        let me = try await client.myself()
        #expect(me.id == "me")

        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let created = try await client.createWorklog(issueId: "1", WorklogDraft(started: started, timeSpentSeconds: 3600, descriptions: ["A", "B"]))
        #expect(created.comment == "• A\n• B")
        let found = try await client.search(jql: "worklogAuthor = currentUser() AND updated >= \"2020/01/01 00:00\"")
        #expect(found.map(\.key) == ["ABC-1"])

        let updated = try await client.updateWorklog(issueId: "1", worklogId: created.id, WorklogDraft(started: started, timeSpentSeconds: 5400, descriptions: ["A"]))
        #expect(updated.timeSpentSeconds == 5400)
        #expect(updated.comment == "A")

        let all = try await client.worklogs(issueId: "1")
        #expect(all.count == 1)

        try await client.deleteWorklog(issueId: "1", worklogId: created.id)
        #expect(try await client.worklogs(issueId: "1").isEmpty)
    }

    @Test func errors() async throws {
        let server = MockJiraServer(kind: .cloud)
        await server.add(.init(id: "1", key: "ABC-1", summary: "Closed", statusCategory: "done", rejectWorklogs: "Issue is closed."))
        let bad = JiraClient(site: site(.cloud, secret: "nope"), transport: server)
        await #expect(throws: JiraError.unauthorized) { try await bad.myself() }

        let c = JiraClient(site: site(.cloud), transport: server, sleep: { _ in })
        await #expect(throws: JiraError.validation("Issue is closed.")) {
            try await c.createWorklog(issueId: "1", WorklogDraft(started: Date(), timeSpentSeconds: 60, descriptions: []))
        }
        await #expect(throws: JiraError.notFound) { try await c.issue("NOPE-1") }

        await server.setOffline(true)
        await #expect(throws: JiraError.offline) { try await c.myself() }
        await server.setOffline(false)

        // 429 waits for Retry-After and continues by itself
        await server.inject(status: 429, headers: ["Retry-After": "2"])
        let waits = WaitLog()
        let c2 = JiraClient(site: site(.cloud), transport: server, onRateLimit: { s in Task { await waits.add(s) } }, sleep: { _ in })
        #expect(try await c2.myself().id == "me")

        // SSO sign-in page instead of the API (VPN off)
        await server.setSignInPage("<html><form action=\"https://login.microsoftonline.com/x/saml2\" method=\"post\"></form></html>")
        await #expect(throws: JiraError.signInPage("login.microsoftonline.com")) { try await c.myself() }
        await server.setSignInPage(nil)

        // 5xx retried twice, then surfaced
        for _ in 0..<3 { await server.inject(status: 503) }
        await #expect(throws: JiraError.server(503)) { try await c.myself() }
    }

    @Test func paginationCloudAndDC() async throws {
        for kind in [JiraKind.cloud, .dataCenter] {
            let server = MockJiraServer(kind: kind)
            for n in 1...25 { await server.add(.init(id: "\(n)", key: "ABC-\(n)", summary: "Task \(n)", assignee: "me")) }
            let c = JiraClient(site: site(kind), transport: server)
            let all = try await c.search(jql: "assignee = currentUser()", maxResults: 10)
            #expect(all.count == 25)
        }
    }

    @Test func exactKeyAndText() async throws {
        let server = MockJiraServer(kind: .cloud)
        await server.add(.init(id: "1", key: "PMO-415", summary: "Steering committee prep"))
        await server.add(.init(id: "2", key: "ABC-9", summary: "Payment gateway"))
        let c = JiraClient(site: site(.cloud), transport: server)
        #expect(try await c.issue("PMO-415").id == "1")
        #expect(try await c.search(jql: "text ~ \"gateway*\"").map(\.key) == ["ABC-9"])
    }
}

actor WaitLog {
    var values: [TimeInterval] = []
    func add(_ v: TimeInterval) { values.append(v) }
}
