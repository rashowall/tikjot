import Foundation
import TikjotDomain

/// Sends HTTP requests. `URLSession` in the app, a mock Jira server in tests and demo mode.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = URLSessionTransport.jiraSession) { self.session = session }

    /// No cookies, no cache, nothing on disk; redirects only within the same origin (the token never leaves the site).
    public static let jiraSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCredentialStorage = nil
        return URLSession(configuration: c, delegate: SameOriginRedirects(), delegateQueue: nil)
    }()

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw JiraError.invalidResponse("not HTTP") }
            return (data, http)
        } catch let e as URLError {
            throw Self.map(e)
        }
    }

    /// `.offline` / `.hostNotFound` / `.noAnswer` only when the request provably never left the Mac; a dropped or
    /// timed-out request may have reached Jira (`.outcomeUnknown`; the client turns that into `.noAnswer` for reads).
    static func map(_ e: URLError) -> JiraError {
        switch e.code {
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            return .offline
        case .cannotFindHost, .dnsLookupFailed:
            return .hostNotFound
        case .cannotConnectToHost:
            return .noAnswer
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot:
            return .untrustedCertificate
        case .secureConnectionFailed:
            return isTrustFailure(e) ? .untrustedCertificate : .invalidResponse("A secure connection to Jira couldn't be made.")
        case .clientCertificateRequired, .clientCertificateRejected:
            return .invalidResponse("Jira asks for a client certificate, which tikjot doesn't support.")
        case .userAuthenticationRequired:
            return .invalidResponse("Jira (or a proxy in front of it) asks for a sign-in tikjot can't do.")
        case .appTransportSecurityRequiresSecureConnection:
            return .insecure
        case .badURL, .unsupportedURL:
            return .badURL
        default:
            return .outcomeUnknown
        }
    }

    /// A TLS failure because of the certificate (the server's trust was evaluated and refused, or a certificate
    /// error code from Secure Transport), not e.g. a protocol mismatch.
    static func isTrustFailure(_ e: URLError) -> Bool {
        if e.userInfo[NSURLErrorFailingURLPeerTrustErrorKey] != nil { return true }
        // errSSLXCertChainInvalid, errSSLBadCert, errSSLUnknownRootCert, errSSLNoRootCert, errSSLCertExpired,
        // errSSLCertNotYetValid, errSSLHostNameMismatch
        let certCodes: Set<Int> = [-9807, -9808, -9812, -9813, -9814, -9815, -9843]
        let stream = (e.userInfo["_kCFStreamErrorCodeKey"] as? Int)
            ?? ((e.userInfo[NSUnderlyingErrorKey] as? NSError)?.userInfo["_kCFStreamErrorCodeKey"] as? Int)
        return stream.map(certCodes.contains) ?? false
    }
}

/// Follows a redirect only to the same scheme, host and port; anything else comes back as the 3xx response,
/// so the Authorization header is never sent to another origin.
final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let from = task.originalRequest?.url ?? response.url, let to = request.url, Self.sameOrigin(from, to) else { return nil }
        return request
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func origin(_ u: URL) -> (String, String, Int)? {
            guard let scheme = u.scheme?.lowercased(), let host = u.host()?.lowercased() else { return nil }
            return (scheme, host, u.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1))
        }
        guard let x = origin(a), let y = origin(b) else { return false }
        return x == y
    }
}

/// Limits concurrent requests per instance (§9.9: max 4).
actor RequestGate {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}

extension JiraSite {
    /// Which Jira answers at this address — asked before signing in, so the connect form can set Cloud / Data Center
    /// itself (beta 2026-10-18: a tester left Jira Cloud on for a Data Center). `serverInfo` answers without a
    /// sign-in on both; nil when the address can't be reached or doesn't say (VPN off, a sign-in page in front, a
    /// typo) — then you choose. `*.atlassian.net` / `*.jira.com` are Cloud without asking.
    public static func detectKind(at baseURL: URL, transport: any HTTPTransport = URLSessionTransport()) async -> JiraKind? {
        if let host = baseURL.host(), isCloudHost(host) { return .cloud }
        guard baseURL.scheme?.lowercased() == "https" else { return nil }
        var req = URLRequest(url: baseURL.appendingPathComponent("rest/api/2/serverInfo"), timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, http) = try? await transport.send(req), http.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = (o["deploymentType"] as? String)?.lowercased() else { return nil }
        switch type {
        case "cloud": return .cloud
        case "server", "datacenter": return .dataCenter
        default: return nil
        }
    }
}

/// One client per connected Jira site. Cloud uses REST v3 + ADF, Data Center REST v2 + wiki markup (§9.2).
public final class JiraClient: Sendable {
    public let site: JiraSite
    let transport: any HTTPTransport
    let gate = RequestGate(limit: 4)
    /// Called while waiting for `Retry-After` (UI: "Jira asked us to slow down").
    let onRateLimit: (@Sendable (TimeInterval) -> Void)?
    let maxRateLimitWait: TimeInterval
    let sleep: @Sendable (TimeInterval) async throws -> Void

    public static let fields = ["summary", "status", "issuetype", "parent", "assignee", "timeoriginalestimate", "timespent", "updated", "project"]

    public init(site: JiraSite, transport: any HTTPTransport = URLSessionTransport(),
                onRateLimit: (@Sendable (TimeInterval) -> Void)? = nil, maxRateLimitWait: TimeInterval = 300,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: JiraClient.nanoseconds($0)) }) {
        self.site = site
        self.transport = transport
        self.onRateLimit = onRateLimit
        self.maxRateLimitWait = maxRateLimitWait
        self.sleep = sleep
    }

    var api: String { "rest/api/\(site.apiVersion)" }

    /// Seconds → nanoseconds without trapping on NaN, infinity or huge values (at most a day).
    public static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(min(seconds, 86_400) * 1_000_000_000)
    }

    /// `Retry-After` in seconds (the HTTP-date form is ignored); finite, never negative, at most `cap`.
    static func retryAfter(_ http: HTTPURLResponse, cap: TimeInterval) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              let v = Double(raw), v.isFinite else { return nil }
        return min(max(v, 0), max(cap, 0))
    }

    /// Most rate-limit / maintenance waits honoured in one request before giving up.
    static let maxRateLimitRetries = 5

    // MARK: Requests

    /// `idempotent`: safe to send again when the answer is lost (reads; defaults to GET). Writes are never
    /// repeated after a timeout or a 5xx — Jira may have done them already; only 429 (Jira refused before doing
    /// anything) is waited out and retried for writes, 429 / 503 + Retry-After for reads.
    /// `signIn`: the connect check — a 401 throws `JiraSignInProblem` (what was refused, and why) instead of `.unauthorized`.
    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Any? = nil, idempotent: Bool? = nil,
                 signIn: Bool = false) async throws -> Any? {
        let idempotent = idempotent ?? (method == "GET")
        var comps = URLComponents(url: site.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else { throw JiraError.badURL }
        // The token goes with every request: never over plain http (an old saved address, a hand-edited backup).
        guard url.scheme?.lowercased() == "https" else { throw JiraError.insecure }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue(site.credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var waited: TimeInterval = 0
        var serverRetries = 0
        var rateLimitRetries = 0
        while true {
            await gate.acquire()
            let result: (Data, HTTPURLResponse)
            do {
                result = try await transport.send(req)
                await gate.release()
            } catch {
                await gate.release()
                let e = (error as? JiraError) ?? (idempotent ? .offline : .outcomeUnknown)
                // A lost answer to a read is just "Jira doesn't answer".
                throw e == .outcomeUnknown && idempotent ? JiraError.noAnswer : e
            }
            let (data, http) = result
            let retryAfter = Self.retryAfter(http, cap: maxRateLimitWait)
            switch http.statusCode {
            case 200..<300:
                if data.isEmpty { return nil }
                if let json = try? JSONSerialization.jsonObject(with: data) { return json }
                // A web page instead of JSON: SSO / reverse proxy sign-in in front of Jira.
                throw JiraError.signInPage(Self.signInHost(data, contentType: http.value(forHTTPHeaderField: "Content-Type")))
            case 401 where Self.wantsCaptcha(http), 403 where Self.wantsCaptcha(http):
                throw JiraError.captcha
            case 401:
                if signIn {
                    throw JiraSignInProblem.classify(kind: site.kind, method: site.credentials.method, sso: Self.signalsSSO(http, data))
                }
                throw JiraError.unauthorized
            case 403:
                throw JiraError.forbidden(Self.errorMessages(data))
            case 404:
                throw JiraError.notFound
            case _ where http.statusCode == 429 || http.statusCode == 503 && retryAfter != nil && idempotent:
                // Jira refused before doing anything (429), or is in maintenance for a read: wait as asked and send
                // again. A 503 on a write may come from a proxy after Jira did it — surfaced below, never repeated.
                let after = retryAfter ?? min(60, pow(2, Double(rateLimitRetries + 1)) + Double.random(in: 0...1))
                if waited + after > maxRateLimitWait || rateLimitRetries >= Self.maxRateLimitRetries {
                    throw http.statusCode == 429 ? JiraError.rateLimited(retryAfter: after) : JiraError.server(http.statusCode)
                }
                onRateLimit?(after)
                waited += after
                rateLimitRetries += 1
                try await sleep(after)
            case 400, 409, 422:
                throw JiraError.validation(Self.errorMessages(data))
            case 500...599:
                // Reads: exponential backoff with jitter, a couple of times, then give up (the caller retries later).
                // Writes: Jira may have saved it — surface at once, the caller checks before writing again.
                if !idempotent || serverRetries >= 2 { throw JiraError.server(http.statusCode) }
                serverRetries += 1
                try await sleep(pow(2, Double(serverRetries)) + Double.random(in: 0...0.5))
            case 300..<400:
                throw JiraError.invalidResponse("Jira redirected to another address (HTTP \(http.statusCode)). Check the site address.")
            default:
                throw JiraError.invalidResponse("HTTP \(http.statusCode)")
            }
        }
    }

    /// Data Center after a few failed sign-ins: every request is refused until someone solves a CAPTCHA in the browser.
    static func wantsCaptcha(_ http: HTTPURLResponse) -> Bool {
        (http.value(forHTTPHeaderField: "X-Seraph-LoginReason") ?? "").uppercased().contains("AUTHENTICATION_DENIED")
    }

    /// A 401 that says the server signs in through company SSO, so a password can't work: a challenge other than
    /// Basic (Negotiate, Bearer, SAML — Jira's own `OAuth realm=` aside), a pointer to Microsoft / Okta / ADFS / SAML,
    /// or Data Center's "basic authentication has been disabled".
    static func signalsSSO(_ http: HTTPURLResponse, _ data: Data) -> Bool {
        let challenge = (http.value(forHTTPHeaderField: "WWW-Authenticate") ?? "").lowercased()
        if !challenge.isEmpty && !challenge.contains("basic") && !challenge.hasPrefix("oauth") { return true }
        let text = ((http.value(forHTTPHeaderField: "Location") ?? "") + " " + String(decoding: data.prefix(4000), as: UTF8.self)).lowercased()
        let markers = ["login.microsoftonline.com", "okta", "saml", "adfs", "basic authentication has been disabled", "basic auth is disabled"]
        return markers.contains(where: text.contains)
    }

    /// Where the page wants to send you ("login.microsoftonline.com"), if it says.
    static func signInHost(_ data: Data, contentType: String?) -> String {
        let text = String(decoding: data.prefix(4000), as: UTF8.self)
        if let r = text.range(of: #"https?://[^/"' ]+"#, options: .regularExpression) {
            return URL(string: String(text[r]))?.host() ?? ""
        }
        return contentType ?? ""
    }

    static func errorMessages(_ data: Data) -> String {
        // Only Jira's own error messages (shown to the user, never logged); a raw body (HTML, proxy page) is dropped.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        var parts = (obj["errorMessages"] as? [String]) ?? []
        if let errs = obj["errors"] as? [String: Any] {
            parts += errs.values.compactMap { $0 as? String }
        }
        let text = parts.joined(separator: " ")
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    // MARK: API (§9.2)

    public func myself() async throws -> JiraUser {
        try await myself(signIn: false)
    }

    /// The connect check (§9.1): `/myself`, with a refused sign-in explained (`JiraSignInProblem`).
    public func testConnection() async throws -> JiraUser {
        try await myself(signIn: true)
    }

    func myself(signIn: Bool) async throws -> JiraUser {
        guard let o = try await request("GET", "\(api)/myself", signIn: signIn) as? [String: Any] else { throw JiraError.invalidResponse("myself") }
        // Without an account id tikjot can't tell your worklogs from colleagues' — refuse rather than guess.
        guard let id = [o["accountId"], o["name"], o["key"]].lazy.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else {
            throw JiraError.invalidResponse("Jira didn't say which account this is.")
        }
        return JiraUser(id: id, displayName: (o["displayName"] as? String) ?? id,
                        email: o["emailAddress"] as? String, timeZone: o["timeZone"] as? String)
    }

    /// Runs a JQL search through all pages (Cloud: token pagination; DC: startAt).
    public func search(jql: String, maxResults: Int = 100, limit: Int = 1000) async throws -> [JiraIssue] {
        var out: [JiraIssue] = []
        // Never loop forever on a misbehaving server: stop on an empty page, a repeated token, or after a page cap.
        let maxPages = 500
        var pages = 0
        if site.kind == .cloud {
            var token: String?
            var seenTokens = Set<String>()
            repeat {
                var body: [String: Any] = ["jql": jql, "fields": Self.fields, "maxResults": maxResults]
                if let token { body["nextPageToken"] = token }
                guard let o = try await request("POST", "\(api)/search/jql", body: body, idempotent: true) as? [String: Any] else { break }
                pages += 1
                let page = ((o["issues"] as? [[String: Any]]) ?? []).compactMap(Self.parseIssue)
                out += page
                token = (o["isLast"] as? Bool) == true ? nil : o["nextPageToken"] as? String
                if page.isEmpty { break }
                if let t = token, !seenTokens.insert(t).inserted { break }
            } while token != nil && out.count < limit && pages < maxPages
        } else {
            var startAt = 0
            while out.count < limit && pages < maxPages {
                let body: [String: Any] = ["jql": jql, "fields": Self.fields, "maxResults": maxResults, "startAt": startAt]
                guard let o = try await request("POST", "\(api)/search", body: body, idempotent: true) as? [String: Any] else { break }
                pages += 1
                let page = ((o["issues"] as? [[String: Any]]) ?? []).compactMap(Self.parseIssue)
                out += page
                let total = (o["total"] as? Int) ?? 0
                startAt += page.count
                if page.isEmpty || startAt >= total { break }
            }
        }
        return out
    }

    /// Fetch one issue by key or id (exact key typed in search, §10.2).
    public func issue(_ keyOrId: String) async throws -> JiraIssue {
        guard JiraIdentifier.isId(keyOrId) || JiraIdentifier.isKey(keyOrId) else { throw JiraIdentifier.invalid }
        let fields = Self.fields.joined(separator: ",")
        guard let o = try await request("GET", "\(api)/issue/\(keyOrId)", query: [URLQueryItem(name: "fields", value: fields)]) as? [String: Any],
              let i = Self.parseIssue(o) else { throw JiraError.notFound }
        return i
    }

    /// All worklogs of an issue (optionally started after a date), all authors.
    public func worklogs(issueId: String, startedAfter: Date? = nil) async throws -> [JiraWorklog] {
        try JiraIdentifier.check(issueId)
        var out: [JiraWorklog] = []
        var startAt = 0
        // Never loop forever on a misbehaving server (a total that never comes): at most 100 pages.
        var pages = 0
        while pages < 100 {
            pages += 1
            var q = [URLQueryItem(name: "startAt", value: "\(startAt)"), URLQueryItem(name: "maxResults", value: "1000")]
            if let startedAfter, site.kind == .cloud {
                q.append(URLQueryItem(name: "startedAfter", value: "\(Int64(startedAfter.timeIntervalSince1970 * 1000))"))
            }
            guard let o = try await request("GET", "\(api)/issue/\(issueId)/worklog", query: q) as? [String: Any] else { break }
            let page = ((o["worklogs"] as? [[String: Any]]) ?? []).compactMap { parseWorklog($0, issueId: issueId) }
            out += page
            let total = (o["total"] as? Int) ?? out.count
            startAt += page.count
            if page.isEmpty || startAt >= total { break }
        }
        if let startedAfter { out = out.filter { $0.started >= startedAfter } }
        return out
    }

    /// One worklog (to check whose it is before changing it).
    public func worklog(issueId: String, worklogId: String) async throws -> JiraWorklog {
        try JiraIdentifier.check(issueId, worklogId)
        guard let o = try await request("GET", "\(api)/issue/\(issueId)/worklog/\(worklogId)") as? [String: Any],
              let w = parseWorklog(o, issueId: issueId) else { throw JiraError.invalidResponse("worklog") }
        return w
    }

    public func createWorklog(issueId: String, _ draft: WorklogDraft) async throws -> JiraWorklog {
        try JiraIdentifier.check(issueId)
        guard let o = try await request("POST", "\(api)/issue/\(issueId)/worklog",
                                        query: [URLQueryItem(name: "adjustEstimate", value: "auto")],
                                        body: worklogBody(draft)) as? [String: Any],
              let w = parseWorklog(o, issueId: issueId) else { throw JiraError.invalidResponse("worklog") }
        return w
    }

    public func updateWorklog(issueId: String, worklogId: String, _ draft: WorklogDraft) async throws -> JiraWorklog {
        try JiraIdentifier.check(issueId, worklogId)
        guard let o = try await request("PUT", "\(api)/issue/\(issueId)/worklog/\(worklogId)",
                                        query: [URLQueryItem(name: "adjustEstimate", value: "auto")],
                                        body: worklogBody(draft)) as? [String: Any],
              let w = parseWorklog(o, issueId: issueId) else { throw JiraError.invalidResponse("worklog") }
        return w
    }

    public func deleteWorklog(issueId: String, worklogId: String) async throws {
        try JiraIdentifier.check(issueId, worklogId)
        _ = try await request("DELETE", "\(api)/issue/\(issueId)/worklog/\(worklogId)",
                              query: [URLQueryItem(name: "adjustEstimate", value: "auto")])
    }

    /// JQL of a saved filter.
    public func filterJQL(id: String) async throws -> (name: String, jql: String) {
        try JiraIdentifier.check(id)
        guard let o = try await request("GET", "\(api)/filter/\(id)") as? [String: Any],
              let jql = o["jql"] as? String else { throw JiraError.notFound }
        return ((o["name"] as? String) ?? "Filter \(id)", jql)
    }

    // MARK: Parsing

    func worklogBody(_ d: WorklogDraft) -> [String: Any] {
        let text = d.plainComment
        var body: [String: Any] = ["started": JiraDate.format(d.started), "timeSpentSeconds": d.timeSpentSeconds]
        if site.kind == .cloud {
            body["comment"] = CommentRenderer.adf(text)
        } else {
            body["comment"] = CommentRenderer.wiki(text)
        }
        return body
    }

    func parseWorklog(_ o: [String: Any], issueId: String) -> JiraWorklog? {
        guard let id = (o["id"] as? String) ?? (o["id"] as? Int).map(String.init),
              let startedS = o["started"] as? String, let started = JiraDate.parse(startedS) else { return nil }
        let author = o["author"] as? [String: Any]
        let authorId = (author?["accountId"] as? String) ?? (author?["name"] as? String) ?? (author?["key"] as? String) ?? ""
        let comment: String
        if site.kind == .cloud {
            comment = CommentRenderer.plain(fromADF: o["comment"])
        } else {
            comment = CommentRenderer.plain(fromWiki: (o["comment"] as? String) ?? "")
        }
        let updated = (o["updated"] as? String).flatMap(JiraDate.parse) ?? started
        let iid = (o["issueId"] as? String) ?? issueId
        return JiraWorklog(id: id, issueId: iid, authorId: authorId, started: started,
                           timeSpentSeconds: (o["timeSpentSeconds"] as? Int) ?? 0, comment: comment, updated: updated)
    }

    static func parseIssue(_ o: [String: Any]) -> JiraIssue? {
        guard let id = (o["id"] as? String) ?? (o["id"] as? Int).map(String.init), let key = o["key"] as? String else { return nil }
        let f = (o["fields"] as? [String: Any]) ?? [:]
        let status = f["status"] as? [String: Any]
        let cat = ((status?["statusCategory"] as? [String: Any])?["key"] as? String) ?? "indeterminate"
        let parent = f["parent"] as? [String: Any]
        let assignee = f["assignee"] as? [String: Any]
        let project = f["project"] as? [String: Any]
        return JiraIssue(
            id: id, key: key, summary: (f["summary"] as? String) ?? key,
            issueType: (f["issuetype"] as? [String: Any])?["name"] as? String,
            statusName: status?["name"] as? String,
            statusCategory: StatusCategory(rawValue: cat) ?? .indeterminate,
            parentKey: parent?["key"] as? String,
            parentSummary: (parent?["fields"] as? [String: Any])?["summary"] as? String,
            assigneeId: (assignee?["accountId"] as? String) ?? (assignee?["name"] as? String),
            originalEstimateSeconds: f["timeoriginalestimate"] as? Int,
            timeSpentSeconds: f["timespent"] as? Int,
            updated: (f["updated"] as? String).flatMap(JiraDate.parse),
            projectKey: project?["key"] as? String,
            projectName: project?["name"] as? String)
    }
}

/// Issue / worklog / filter ids and issue keys go into URL paths and JQL. They come from the database (a backup
/// can be hand-edited), so anything else than digits or `KEY-123` never makes a request.
public enum JiraIdentifier {
    public static let invalid = JiraError.validation("Not a valid Jira task or worklog id.")

    /// Digits only (`10001`).
    public static func isId(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 19 && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// `ABC-123`: an upper-case letter, then upper-case letters, digits or `_`, a dash and digits.
    public static func isKey(_ s: String) -> Bool {
        guard s.count <= 255, let dash = s.lastIndex(of: "-") else { return false }
        let project = s[..<dash].unicodeScalars, number = String(s[s.index(after: dash)...])
        guard project.count >= 2, let first = project.first, ("A"..."Z").contains(first) else { return false }
        return project.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" } && isId(number)
    }

    static func check(_ ids: String...) throws {
        guard ids.allSatisfy(isId) else { throw invalid }
    }
}

/// Jira's timestamp format: `2026-10-01T09:15:00.000+0200`.
public enum JiraDate {
    private static let formatters: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"].map { f in
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = f
        return df
    }

    public static func format(_ d: Date, timeZone: TimeZone = .current) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.timeZone = timeZone
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return df.string(from: d)
    }

    public static func parse(_ s: String) -> Date? {
        for f in formatters { if let d = f.date(from: s) { return d } }
        return ISO8601DateFormatter().date(from: s)
    }

    /// JQL date literal "yyyy/MM/dd HH:mm". A JQL date has no offset: in the hour the clocks go back the same
    /// reading happens twice, and Jira may take the later one — so a time in the first pass is written as the
    /// minute before the repeated hour (a window that starts a little early, never late).
    public static func jql(_ d: Date, timeZone: TimeZone = .current) -> String {
        var d = d
        if let next = timeZone.nextDaylightSavingTimeTransition(after: d) {
            let back = timeZone.secondsFromGMT(for: next.addingTimeInterval(-1)) - timeZone.secondsFromGMT(for: next)
            if back > 0, next.timeIntervalSince(d) <= TimeInterval(back) {
                d = next.addingTimeInterval(-TimeInterval(back) - 60)
            }
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.timeZone = timeZone
        df.dateFormat = "yyyy/MM/dd HH:mm"
        return df.string(from: d)
    }
}
