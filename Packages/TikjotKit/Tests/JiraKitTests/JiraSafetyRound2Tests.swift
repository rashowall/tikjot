import Foundation
import Testing
import TikjotDomain
@testable import JiraKit

/// Counts requests; every list of worklogs claims more to come.
actor EndlessWorklogs: HTTPTransport {
    var count = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        let w: [String: Any] = ["id": "\(count)", "started": "2026-10-01T09:00:00.000+0200", "timeSpentSeconds": 60]
        let o: [String: Any] = ["worklogs": [w], "total": Int.max]
        return (try JSONSerialization.data(withJSONObject: o), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct JiraSafetyRound2Tests {
    let draft = WorklogDraft(started: Date(timeIntervalSince1970: 1_790_000_000), timeSpentSeconds: 3600, descriptions: ["A"])

    @Test func identifiers() {
        #expect(JiraIdentifier.isId("10001"))
        for bad in ["", "1/../../myself", "1?x=1", "１２", "-1", "1 ", "1\n", "12345678901234567890"] { #expect(!JiraIdentifier.isId(bad), "\(bad)") }
        #expect(JiraIdentifier.isKey("ABC-1") && JiraIdentifier.isKey("A_2-10"))
        for bad in ["abc-1", "A-1", "ABC-", "ABC-1\n", "ABC-1 OR x", "1BC-1", "ABC-1/worklog", "ÄBC-1"] { #expect(!JiraIdentifier.isKey(bad), "\(bad)") }
    }

    @Test func invalidIdsNeverMakeARequest() async throws {
        let server = MockJiraServer(kind: .cloud)
        let c = JiraClient(site: site(.cloud), transport: server, sleep: { _ in })
        await #expect(throws: JiraIdentifier.invalid) { try await c.createWorklog(issueId: "1/../../../rest/api/3/myself", draft) }
        await #expect(throws: JiraIdentifier.invalid) { try await c.deleteWorklog(issueId: "1", worklogId: "2?x") }
        await #expect(throws: JiraIdentifier.invalid) { try await c.updateWorklog(issueId: "1", worklogId: "../3", draft) }
        await #expect(throws: JiraIdentifier.invalid) { try await c.worklog(issueId: "x", worklogId: "1") }
        await #expect(throws: JiraIdentifier.invalid) { try await c.worklogs(issueId: "1 OR 2") }
        await #expect(throws: JiraIdentifier.invalid) { try await c.issue("../myself") }
        await #expect(throws: JiraIdentifier.invalid) { try await c.filterJQL(id: "1/share") }
        #expect(await server.requestLog.isEmpty)
        // An invalid id is a definite refusal: nothing reached Jira.
        #expect(!JiraIdentifier.invalid.mayHaveReachedJira)
    }

    @Test func signInPageOnAWriteMayHaveReachedJira() {
        #expect(JiraError.signInPage("sso.acme.com").mayHaveReachedJira)
    }

    @Test func worklogListingStopsAfterAPageCap() async throws {
        let t = EndlessWorklogs()
        let c = JiraClient(site: site(.dataCenter), transport: t, sleep: { _ in })
        let ws = try await c.worklogs(issueId: "1")
        #expect(ws.count == 100)
        #expect(await t.count == 100)
    }
}
