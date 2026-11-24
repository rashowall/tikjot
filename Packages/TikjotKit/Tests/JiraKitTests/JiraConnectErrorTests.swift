import Foundation
import Testing
import TikjotDomain
@testable import JiraKit

/// Answers every request from a fixed stub: a URLError, or an HTTP status with headers and body (no network).
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case fail(URLError), http(Int, [String: String], String) }
    nonisolated(unsafe) static var reply: Reply = .fail(URLError(.timedOut))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch Self.reply {
        case .fail(let e):
            client?.urlProtocol(self, didFailWithError: e)
        case .http(let status, let headers, let body):
            let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// Connect check errors by actual cause (§9.1): what was refused and why, network problems told apart.
@Suite(.serialized) struct JiraConnectErrorTests {
    func client(_ kind: JiraKind, _ method: JiraAuthMethod) -> JiraClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let s = JiraSite(kind: kind, baseURL: URL(string: kind == .cloud ? "https://acme.atlassian.net" : "https://jira.acme.com")!,
                         credentials: JiraCredentials(method: method, login: "me", secret: "x"))
        return JiraClient(site: s, transport: URLSessionTransport(session: URLSession(configuration: config)), sleep: { _ in })
    }

    func signIn(_ kind: JiraKind, _ method: JiraAuthMethod, _ reply: StubURLProtocol.Reply) async -> Error? {
        StubURLProtocol.reply = reply
        do { _ = try await client(kind, method).testConnection(); return nil } catch { return error }
    }

    // MARK: 401 / 403

    @Test func refusedDetailsSayWhatToUse() async {
        let oauth = ["WWW-Authenticate": "OAuth realm=\"https%3A%2F%2Fjira.acme.com\""]
        #expect(await signIn(.cloud, .cloudApiToken, .http(401, [:], "")) as? JiraSignInProblem == .cloudNeedsAPIToken)
        // Cloud stays "use an API token" even when the body mentions SSO.
        #expect(await signIn(.cloud, .cloudApiToken, .http(401, [:], "okta")) as? JiraSignInProblem == .cloudNeedsAPIToken)
        #expect(await signIn(.dataCenter, .pat, .http(401, oauth, "")) as? JiraSignInProblem == .tokenMismatch)
        // Jira's own OAuth challenge on a plain wrong password is not SSO.
        #expect(await signIn(.dataCenter, .basic, .http(401, oauth, "{}")) as? JiraSignInProblem == .wrongPassword)
        #expect(await signIn(.dataCenter, .basic, .http(401, ["WWW-Authenticate": "Basic realm=\"Jira\""], "")) as? JiraSignInProblem == .wrongPassword)
    }

    @Test func passwordBehindCompanySSO() async {
        #expect(await signIn(.dataCenter, .basic, .http(401, ["WWW-Authenticate": "Negotiate"], "")) as? JiraSignInProblem == .companySSO)
        #expect(await signIn(.dataCenter, .basic, .http(401, ["Location": "https://login.microsoftonline.com/abc/saml2"], "")) as? JiraSignInProblem == .companySSO)
        #expect(await signIn(.dataCenter, .basic, .http(401, [:], "<a href=\"https://acme.okta.com/app/sso\">")) as? JiraSignInProblem == .companySSO)
        #expect(await signIn(.dataCenter, .basic, .http(401, [:], "{\"message\":\"Basic Authentication has been disabled on this instance.\"}")) as? JiraSignInProblem == .companySSO)
    }

    @Test func captchaAfterFailedSignIns() async {
        let h = ["X-Seraph-LoginReason": "AUTHENTICATION_DENIED", "X-Authentication-Denied-Reason": "CAPTCHA_CHALLENGE; login-url=https://jira.acme.com/login.jsp"]
        #expect(await signIn(.dataCenter, .basic, .http(403, h, "")) as? JiraError == .captcha)
        #expect(await signIn(.dataCenter, .basic, .http(401, h, "")) as? JiraError == .captcha)
        // A plain 403 stays "no permission".
        #expect(await signIn(.dataCenter, .pat, .http(403, [:], "")) as? JiraError == .forbidden(""))
    }

    @Test func laterA401IsStillSignedOut() async {
        StubURLProtocol.reply = .http(401, ["WWW-Authenticate": "Negotiate"], "")
        await #expect(throws: JiraError.unauthorized) { try await client(.dataCenter, .basic).myself() }
    }

    @Test func mockServerRefusalsByKind() async throws {
        let dc = MockJiraServer(kind: .dataCenter)
        let pat = JiraClient(site: site(.dataCenter, secret: "nope"), transport: dc)
        await #expect(throws: JiraSignInProblem.tokenMismatch) { try await pat.testConnection() }
        let cloud = MockJiraServer(kind: .cloud)
        let token = JiraClient(site: site(.cloud, secret: "nope"), transport: cloud)
        await #expect(throws: JiraSignInProblem.cloudNeedsAPIToken) { try await token.testConnection() }
        #expect(try await JiraClient(site: site(.cloud), transport: cloud).testConnection().id == "me")
    }

    // MARK: Network

    @Test func networkProblemsThroughURLSession() async {
        #expect(await signIn(.dataCenter, .pat, .fail(URLError(.cannotFindHost))) as? JiraError == .hostNotFound)
        #expect(await signIn(.dataCenter, .pat, .fail(URLError(.dnsLookupFailed))) as? JiraError == .hostNotFound)
        #expect(await signIn(.dataCenter, .pat, .fail(URLError(.timedOut))) as? JiraError == .noAnswer)
        #expect(await signIn(.dataCenter, .pat, .fail(URLError(.cannotConnectToHost))) as? JiraError == .noAnswer)
        #expect(await signIn(.dataCenter, .pat, .fail(URLError(.networkConnectionLost))) as? JiraError == .noAnswer)
        #expect(await signIn(.dataCenter, .pat, .fail(URLError(.notConnectedToInternet))) as? JiraError == .offline)
        #expect(await signIn(.dataCenter, .pat, .fail(URLError(.serverCertificateUntrusted))) as? JiraError == .untrustedCertificate)
        #expect(await signIn(.dataCenter, .pat, .fail(URLError(.serverCertificateHasBadDate))) as? JiraError == .untrustedCertificate)
        #expect(await signIn(.dataCenter, .pat, .fail(URLError(.serverCertificateNotYetValid))) as? JiraError == .untrustedCertificate)
    }

    @Test func secureConnectionFailedIsACertificateOnlyWhenTrustFailed() {
        #expect(URLSessionTransport.map(URLError(.secureConnectionFailed, userInfo: ["_kCFStreamErrorCodeKey": -9813])) == .untrustedCertificate)
        #expect(URLSessionTransport.map(URLError(.secureConnectionFailed, userInfo: [NSUnderlyingErrorKey: NSError(domain: "x", code: 0, userInfo: ["_kCFStreamErrorCodeKey": -9807])])) == .untrustedCertificate)
        let other = URLSessionTransport.map(URLError(.secureConnectionFailed, userInfo: ["_kCFStreamErrorCodeKey": -9836]))
        #expect(other != .untrustedCertificate)
        if case .invalidResponse = other {} else { Issue.record("expected invalidResponse, got \(other)") }
    }

    @Test func newErrorsBehaveLikeTheirKind() {
        for e: JiraError in [.hostNotFound, .noAnswer, .offline] {
            #expect(e.isUnreachable && e.isTransient && !e.mayHaveReachedJira)
        }
        for e: JiraError in [.untrustedCertificate, .captcha] {
            #expect(!e.isUnreachable && !e.isTransient && !e.mayHaveReachedJira)
        }
        #expect(!JiraError.untrustedCertificate.message.contains("VPN"))
        #expect(JiraError.hostNotFound.message.contains("VPN") && JiraError.noAnswer.message.contains("VPN"))
        #expect(Set([JiraError.hostNotFound, .noAnswer, .untrustedCertificate, .captcha].map(\.code)) == ["dns", "noanswer", "cert", "captcha"])
    }

    // MARK: Address

    @Test func pastedJiraLinksBecomeTheSite() throws {
        let n = { (s: String) in try JiraSite.normalizedBaseURL(s).absoluteString }
        #expect(try n("https://acme.atlassian.net/browse/ABC-123") == "https://acme.atlassian.net")
        #expect(try n("acme.atlassian.net/jira/software/projects/ABC/boards/1?selectedIssue=ABC-1") == "https://acme.atlassian.net")
        #expect(try n("https://acme.atlassian.net/jira/your-work") == "https://acme.atlassian.net")
        #expect(try n("https://jira.acme.com/browse/ABC-1") == "https://jira.acme.com")
        #expect(try n("https://jira.acme.com/jira/browse/ABC-1") == "https://jira.acme.com/jira")
        #expect(try n("https://jira.acme.com/jira/secure/Dashboard.jspa") == "https://jira.acme.com/jira")
        #expect(try n("https://jira.acme.com/secure/RapidBoard.jspa?rapidView=5") == "https://jira.acme.com")
        #expect(try n("https://jira.acme.com/projects/ABC/issues/ABC-1") == "https://jira.acme.com")
        #expect(try n("https://jira.acme.com/issues/?jql=project%3DABC") == "https://jira.acme.com")
        #expect(try n("https://jira.acme.com/plugins/servlet/ac/tempo/tempo-my-work") == "https://jira.acme.com")
        #expect(try n("https://jira.acme.com/login.jsp?os_destination=%2Fbrowse") == "https://jira.acme.com")
        #expect(try n("https://jira.acme.com/tools/jira/Dashboard.jspa") == "https://jira.acme.com/tools/jira")
        #expect(try n("https://jira.acme.com/dashboard") == "https://jira.acme.com")
        #expect(try n("https://jira.acme.com/jira/software/c/projects/ABC") == "https://jira.acme.com")
        #expect(try n("https://jira.acme.com:8443/jira/core/projects/X/board") == "https://jira.acme.com:8443")
        // A real context path stays.
        #expect(try n("https://jira.acme.com/jira/") == "https://jira.acme.com/jira")
        #expect(try n("https://acme.com/tools/jira") == "https://acme.com/tools/jira")
    }

    @Test func kindHintForTheAddress() {
        #expect(JiraSite.kindHint(for: "jira.acme.com", chosen: .cloud) == .dataCenter)
        #expect(JiraSite.kindHint(for: "https://jira.acme.com/jira", chosen: .cloud) == .dataCenter)
        #expect(JiraSite.kindHint(for: "acme.atlassian.net", chosen: .dataCenter) == .cloud)
        #expect(JiraSite.kindHint(for: "acme.jira.com", chosen: .dataCenter) == .cloud)
        #expect(JiraSite.kindHint(for: "acme.atlassian.net", chosen: .cloud) == nil)
        #expect(JiraSite.kindHint(for: "jira.acme.com", chosen: .dataCenter) == nil)
        // Still typing: no hint.
        for typing in ["", "acme", "acme.", "acme.a", "acme.atlassian", "acme.atlassian.n", "acme.jira.c", "http://"] {
            #expect(JiraSite.kindHint(for: typing, chosen: .cloud) == nil, "\(typing)")
        }
    }
}
/// The connect form asks the address what it is before signing in (beta 2026-10-18).
@Suite struct JiraKindDetectionTests {
    @Test func theAddressSaysWhatItIs() async {
        let dc = URL(string: "https://jira.acme.com")!
        #expect(await JiraSite.detectKind(at: dc, transport: MockJiraServer(kind: .dataCenter)) == .dataCenter)
        #expect(await JiraSite.detectKind(at: dc, transport: MockJiraServer(kind: .cloud)) == .cloud)
        // atlassian.net is Cloud without asking; not reachable → nil (you choose).
        let off = MockJiraServer(kind: .dataCenter)
        await off.setOffline(true)
        #expect(await JiraSite.detectKind(at: URL(string: "https://acme.atlassian.net")!, transport: off) == .cloud)
        #expect(await JiraSite.detectKind(at: dc, transport: off) == nil)
    }
}
