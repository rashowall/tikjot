import Foundation
import Testing
import TikjotDomain
@testable import JiraKit

/// Fails every request with one URLError (no network is touched).
final class FailingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var code: URLError.Code = .timedOut
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(Self.code)) }
    override func stopLoading() {}
}

/// Cloud search that never ends: the same token again, or a page without issues.
struct LoopingSearch: HTTPTransport {
    let emptyPages: Bool
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let issues: [[String: Any]] = emptyPages ? [] : [["id": "1", "key": "ABC-1", "fields": ["summary": "x"]]]
        let o: [String: Any] = ["issues": issues, "isLast": false, "nextPageToken": "same"]
        return (try JSONSerialization.data(withJSONObject: o), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// Answers with a fixed status / body.
struct FixedResponse: HTTPTransport {
    let status: Int
    let body: String
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite(.serialized) struct JiraSafetyTests {
    let draft = WorklogDraft(started: Date(timeIntervalSince1970: 1_790_000_000), timeSpentSeconds: 3600, descriptions: ["A"])

    @Test func writesAreNotRepeatedAfter5xx() async throws {
        let server = MockJiraServer(kind: .cloud)
        await server.add(.init(id: "1", key: "ABC-1", summary: "x"))
        let c = JiraClient(site: site(.cloud), transport: server, sleep: { _ in })
        await server.inject(status: 500)
        await #expect(throws: JiraError.server(500)) { try await c.createWorklog(issueId: "1", draft) }
        #expect(await server.requestLog.filter { $0.hasPrefix("POST") }.count == 1)
        // 503 + Retry-After on a write: may come from a proxy after Jira did it → surfaced, not repeated.
        await server.clearLog()
        await server.inject(status: 503, headers: ["Retry-After": "1"])
        await #expect(throws: JiraError.server(503)) { try await c.createWorklog(issueId: "1", draft) }
        #expect(await server.requestLog.filter { $0.hasPrefix("POST") }.count == 1)
        // 429: refused before doing anything → waited out and sent again.
        await server.inject(status: 429, headers: ["Retry-After": "1"])
        _ = try await c.createWorklog(issueId: "1", draft)
        #expect(await server.myWorklogs().count == 1)
        // A read waits out 503 + Retry-After.
        await server.inject(status: 503, headers: ["Retry-After": "1"])
        #expect(try await c.myself().id == "me")
        // Reads keep their backoff.
        for _ in 0..<2 { await server.inject(status: 502) }
        #expect(try await c.myself().id == "me")
    }

    @Test func lostAnswerIsUnknownForWritesNoAnswerForReads() async throws {
        let server = MockJiraServer(kind: .cloud)
        await server.add(.init(id: "1", key: "ABC-1", summary: "x"))
        let c = JiraClient(site: site(.cloud), transport: server, sleep: { _ in })
        await server.loseNextResponse(method: "POST")
        await #expect(throws: JiraError.outcomeUnknown) { try await c.createWorklog(issueId: "1", draft) }
        #expect(await server.myWorklogs().count == 1) // it did arrive
        await server.loseNextResponse(method: "GET")
        await #expect(throws: JiraError.noAnswer) { try await c.myself() }
        // Search goes by POST but only reads.
        await server.loseNextResponse(method: "POST")
        await #expect(throws: JiraError.noAnswer) { try await c.search(jql: "key = ABC-1") }
    }

    @Test func urlErrorsMapping() {
        #expect(URLSessionTransport.map(URLError(.timedOut)) == .outcomeUnknown)
        #expect(URLSessionTransport.map(URLError(.networkConnectionLost)) == .outcomeUnknown)
        #expect(URLSessionTransport.map(URLError(.cannotConnectToHost)) == .noAnswer)
        #expect(URLSessionTransport.map(URLError(.notConnectedToInternet)) == .offline)
        #expect(URLSessionTransport.map(URLError(.appTransportSecurityRequiresSecureConnection)) == .insecure)
        for code: URLError.Code in [.clientCertificateRequired, .userAuthenticationRequired, .serverCertificateUntrusted] {
            let e = URLSessionTransport.map(URLError(code))
            #expect(!e.isUnreachable && !e.message.contains("VPN"))
        }
    }

    @Test func urlSessionTimeoutThroughStubbedProtocol() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let transport = URLSessionTransport(session: URLSession(configuration: config))
        let c = JiraClient(site: site(.cloud), transport: transport, sleep: { _ in })
        FailingURLProtocol.code = .timedOut
        await #expect(throws: JiraError.outcomeUnknown) { try await c.createWorklog(issueId: "1", draft) }
        await #expect(throws: JiraError.noAnswer) { try await c.myself() }
        FailingURLProtocol.code = .appTransportSecurityRequiresSecureConnection
        await #expect(throws: JiraError.insecure) { try await c.myself() }
    }

    @Test func dedicatedSessionKeepsNothing() {
        let cfg = URLSessionTransport.jiraSession.configuration
        #expect(cfg.httpCookieStorage == nil)
        #expect(cfg.urlCache == nil)
        #expect(cfg.httpShouldSetCookies == false)
        #expect(cfg.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func redirectsStayOnTheSameOrigin() async {
        let u = { (s: String) in URL(string: s)! }
        #expect(SameOriginRedirects.sameOrigin(u("https://jira.acme.com/a"), u("https://JIRA.acme.com:443/b")))
        #expect(!SameOriginRedirects.sameOrigin(u("https://jira.acme.com"), u("http://jira.acme.com")))
        #expect(!SameOriginRedirects.sameOrigin(u("https://jira.acme.com"), u("https://jira.acme.com:8443")))
        #expect(!SameOriginRedirects.sameOrigin(u("https://jira.acme.com"), u("https://login.example.com")))
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: u("https://jira.acme.com/rest/api/3/myself")) // never resumed
        let response = HTTPURLResponse(url: u("https://jira.acme.com/rest/api/3/myself"), statusCode: 302, httpVersion: nil, headerFields: nil)!
        let d = SameOriginRedirects()
        var away = URLRequest(url: u("https://evil.example.com/collect"))
        away.setValue("Basic x", forHTTPHeaderField: "Authorization")
        #expect(await d.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: away) == nil)
        let same = URLRequest(url: u("https://jira.acme.com/rest/api/3/myself/"))
        #expect(await d.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: same) != nil)
    }

    @Test func retryAfterNeverTraps() async throws {
        #expect(JiraClient.nanoseconds(.nan) == 0)
        #expect(JiraClient.nanoseconds(.infinity) == 0)
        #expect(JiraClient.nanoseconds(-5) == 0)
        #expect(JiraClient.nanoseconds(1e308) == 86_400 * 1_000_000_000)
        func h(_ v: String) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": v])!
        }
        #expect(JiraClient.retryAfter(h("inf"), cap: 300) == nil)
        #expect(JiraClient.retryAfter(h("nan"), cap: 300) == nil)
        #expect(JiraClient.retryAfter(h("-10"), cap: 300) == 0)
        #expect(JiraClient.retryAfter(h("1e308"), cap: 300) == 300)
        #expect(JiraClient.retryAfter(h("Wed, 21 Oct 2026 07:28:00 GMT"), cap: 300) == nil)

        // "Retry-After: 0" forever must not spin: gives up after a few tries.
        let server = MockJiraServer(kind: .cloud)
        for _ in 0..<10 { await server.inject(status: 429, headers: ["Retry-After": "0"]) }
        let c = JiraClient(site: site(.cloud), transport: server, sleep: { _ in })
        await #expect(throws: JiraError.rateLimited(retryAfter: 0)) { try await c.myself() }
    }

    @Test func cloudSearchStopsOnRepeatedTokenOrEmptyPage() async throws {
        let repeated = JiraClient(site: site(.cloud), transport: LoopingSearch(emptyPages: false))
        #expect(try await repeated.search(jql: "x").count == 2)
        let empty = JiraClient(site: site(.cloud), transport: LoopingSearch(emptyPages: true))
        #expect(try await empty.search(jql: "x").isEmpty)
    }

    @Test func baseURLIsHttpsOnly() throws {
        #expect(try JiraSite.normalizedBaseURL(" acme.atlassian.net/ ").absoluteString == "https://acme.atlassian.net")
        #expect(try JiraSite.normalizedBaseURL("HTTPS://Jira.Acme.com:443/jira/?x=1#top").absoluteString == "https://jira.acme.com/jira")
        #expect(try JiraSite.normalizedBaseURL("https://user:pw@jira.acme.com:8443/").absoluteString == "https://jira.acme.com:8443")
        #expect(throws: JiraError.insecure) { try JiraSite.normalizedBaseURL("http://jira.acme.com") }
        #expect(throws: JiraError.insecure) { try JiraSite.normalizedBaseURL("ftp://jira.acme.com") }
        #expect(throws: JiraError.badURL) { try JiraSite.normalizedBaseURL("https://") }
        #expect(throws: JiraError.badURL) { try JiraSite.normalizedBaseURL("  ") }
    }

    @Test func plainHttpSiteIsRefused() async {
        let s = JiraSite(kind: .dataCenter, baseURL: URL(string: "http://jira.acme.com")!, credentials: .init(method: .pat, login: "", secret: "secret"))
        let c = JiraClient(site: s, transport: MockJiraServer(kind: .dataCenter))
        await #expect(throws: JiraError.insecure) { try await c.myself() }
    }

    @Test func serverTextStaysOutOfErrors() async throws {
        let html = JiraClient(site: site(.cloud), transport: FixedResponse(status: 400, body: "<html>secret issue summary</html>"))
        await #expect(throws: JiraError.validation("")) { try await html.myself() }
        let anonymous = JiraClient(site: site(.cloud), transport: FixedResponse(status: 200, body: "{\"displayName\":\"Someone\"}"))
        await #expect(throws: JiraError.self) { try await anonymous.myself() }
    }
}
