import Foundation
import TikjotDomain

public struct JiraCredentials: Sendable, Hashable {
    public var method: JiraAuthMethod
    /// Email (Cloud) or username (DC basic). Unused for PAT.
    public var login: String
    /// API token, PAT or password.
    public var secret: String

    public init(method: JiraAuthMethod, login: String, secret: String) {
        self.method = method; self.login = login; self.secret = secret
    }

    var authorizationHeader: String {
        switch method {
        case .pat:
            return "Bearer \(secret)"
        case .cloudApiToken, .basic:
            return "Basic " + Data("\(login):\(secret)".utf8).base64EncodedString()
        }
    }
}

public struct JiraSite: Sendable, Hashable {
    public var kind: JiraKind
    public var baseURL: URL
    public var credentials: JiraCredentials

    public init(kind: JiraKind, baseURL: URL, credentials: JiraCredentials) {
        self.kind = kind; self.baseURL = baseURL; self.credentials = credentials
    }

    var apiVersion: String { kind == .cloud ? "3" : "2" }

    /// The site address as typed ("acme.atlassian.net", "https://jira.acme.com/jira/") → `https://host[:port][/context]`.
    /// Only https: the token goes in every request. User/password, query and fragment are dropped;
    /// a Data Center context path is kept, without the trailing slash.
    public static func normalizedBaseURL(_ input: String) throws -> URL {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw JiraError.badURL }
        if s.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) == nil { s = "https://" + s }
        guard var c = URLComponents(string: s), let scheme = c.scheme?.lowercased() else { throw JiraError.badURL }
        guard scheme == "https" else { throw JiraError.insecure }
        guard let host = c.host?.lowercased(), !host.isEmpty, !host.contains(" ") else { throw JiraError.badURL }
        c.scheme = scheme
        c.host = host
        c.user = nil
        c.password = nil
        c.query = nil
        c.fragment = nil
        if c.port == 443 { c.port = nil }
        // Jira Cloud has no context path: a pasted board or issue link keeps only the site.
        c.path = isCloudHost(host) ? "" : contextPath(c.path)
        guard let url = c.url else { throw JiraError.badURL }
        return url
    }

    /// Jira Cloud lives at `*.atlassian.net` (older sites `*.jira.com`), always at the root.
    public static func isCloudHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h.hasSuffix(".atlassian.net") || h.hasSuffix(".jira.com")
    }

    /// Jira's own pages in a pasted address ("/browse/ABC-1", "/secure/Dashboard.jspa", "/projects/ABC/issues", …):
    /// everything from there on goes, a real context path before it ("/jira") stays. No trailing slash.
    static func contextPath(_ path: String) -> String {
        let pages: Set<String> = ["browse", "secure", "projects", "issues", "plugins", "rest", "servicedesk", "login"]
        let apps: Set<String> = ["software", "core", "servicedesk", "your-work", "for-you"]
        let parts = path.split(separator: "/")
        var kept: [Substring] = []
        for (i, p) in parts.enumerated() {
            let low = p.lowercased()
            if pages.contains(low) || low.hasPrefix("dashboard") || low.hasSuffix(".jsp") || low.hasSuffix(".jspa") { break }
            // "/jira/software/…", "/jira/core/…" (Cloud-style app paths).
            if low == "jira", i + 1 < parts.count, apps.contains(parts[i + 1].lowercased()) { break }
            kept.append(p)
        }
        return kept.isEmpty ? "" : "/" + kept.joined(separator: "/")
    }

    /// The other kind when the address clearly belongs to it (Cloud picked for `jira.acme.com`, Data Center for
    /// `acme.atlassian.net`) — a hint under the address, never a block. Nil while the address may still be on its
    /// way to a Cloud one (`acme.atl…`).
    public static func kindHint(for input: String, chosen: JiraKind) -> JiraKind? {
        guard let host = (try? normalizedBaseURL(input))?.host()?.lowercased() else { return nil }
        if isCloudHost(host) { return chosen == .cloud ? nil : .cloud }
        guard chosen == .cloud, let dot = host.firstIndex(of: ".") else { return nil }
        let rest = String(host[host.index(after: dot)...])
        guard rest.count >= 2, !["atlassian.net", "jira.com"].contains(where: { $0.hasPrefix(rest) }) else { return nil }
        return .dataCenter
    }

    /// Where the user creates a token (§9.1).
    public var tokenPageURL: URL {
        switch kind {
        case .cloud: return URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!
        case .dataCenter: return baseURL.appendingPathComponent("secure/ViewProfile.jspa")
        }
    }
}

public enum JiraError: Error, Equatable, Sendable {
    /// No network / host unreachable / VPN down.
    case offline
    /// 401
    case unauthorized
    /// 403
    case forbidden(String)
    /// 404
    case notFound
    /// 429 after the allowed retries.
    case rateLimited(retryAfter: TimeInterval)
    /// 400 with Jira's messages (closed issue, bad worklog, …).
    case validation(String)
    /// 5xx
    case server(Int)
    case invalidResponse(String)
    case badURL
    /// The site answered with a web page (company sign-in / SSO in front of Jira) instead of the API —
    /// usually because the Mac is outside the company network (VPN off).
    case signInPage(String)
    /// A write may have reached Jira, but no answer came back (timeout, connection dropped mid-request).
    /// Before writing again tikjot looks in Jira for it (§9.8).
    case outcomeUnknown
    /// Plain http:// — tikjot only talks to Jira over https.
    case insecure
    /// The address doesn't resolve (a typo, or an internal host that resolves only on the company VPN).
    case hostNotFound
    /// The server didn't answer a read (timeout, connection refused or dropped) — often a VPN that hangs.
    case noAnswer
    /// The TLS certificate isn't trusted by this Mac (company CA not installed, expired). Not a VPN matter.
    case untrustedCertificate
    /// Jira (Data Center) wants a CAPTCHA after failed sign-ins (`X-Seraph-LoginReason: AUTHENTICATION_DENIED`).
    case captcha

    /// Stable code stored with failed worklogs.
    public var code: String {
        switch self {
        case .offline: return "offline"
        case .unauthorized: return "401"
        case .forbidden: return "403"
        case .notFound: return "404"
        case .rateLimited: return "429"
        case .validation: return "400"
        case .server(let c): return "\(c)"
        case .invalidResponse: return "invalid"
        case .badURL: return "url"
        case .signInPage: return "sso"
        case .outcomeUnknown: return "unknown"
        case .insecure: return "http"
        case .hostNotFound: return "dns"
        case .noAnswer: return "noanswer"
        case .untrustedCertificate: return "cert"
        case .captcha: return "captcha"
        }
    }

    /// Plain-words reason for the UI (English; the app localises by `code`).
    public var message: String {
        switch self {
        case .offline: return "Jira can't be reached. Check your connection or VPN."
        case .unauthorized: return "Jira signed you out — the token expired or was revoked."
        case .forbidden(let m): return m.isEmpty ? "You don't have permission to log work on this task." : m
        case .notFound: return "The task or worklog no longer exists in Jira."
        case .rateLimited: return "Jira asked us to slow down."
        case .validation(let m): return m.isEmpty ? "Jira rejected the worklog." : m
        case .server(let c): return "Jira had a problem (\(c)). It will be retried."
        case .invalidResponse(let m): return "Unexpected answer from Jira: \(m)"
        case .badURL: return "The Jira address doesn't look right."
        case .signInPage: return "Jira answered with a company sign-in page instead of data. Connect to your company VPN and try again."
        case .outcomeUnknown: return "Jira didn't answer in time. tikjot checks whether the worklog arrived before sending it again."
        case .insecure: return "tikjot connects to Jira only over https://."
        case .hostNotFound: return "No server answers at this address. Check it — and if Jira is on your company network, connect to the VPN."
        case .noAnswer: return "The server doesn't answer. Are you connected to your company VPN? If you are, turn it off and on again."
        case .untrustedCertificate: return "This Mac doesn't trust your Jira's certificate. Your IT can fix it (company certificate in Keychain)."
        case .captcha: return "Jira wants a check after failed sign-ins. Sign in once in your browser, then try again."
        }
    }

    public var isSignInPage: Bool { if case .signInPage = self { return true }; return false }

    /// Jira can't be reached right now (no network, the address doesn't resolve, no answer) — calm, retried by itself.
    public var isUnreachable: Bool { self == .offline || self == .hostNotFound || self == .noAnswer }

    /// Retrying automatically makes sense (the fix isn't the user's, §11.9).
    public var isTransient: Bool {
        switch self {
        case .offline, .hostNotFound, .noAnswer, .server, .rateLimited, .signInPage, .outcomeUnknown: return true
        default: return false
        }
    }

    /// A create that failed this way may still have created the worklog in Jira — never re-send it blindly.
    public var mayHaveReachedJira: Bool {
        switch self {
        // A sign-in page can also come back after Jira did the write (a proxy that rewrote a 2xx answer).
        case .outcomeUnknown, .server, .invalidResponse, .signInPage: return true
        default: return false
        }
    }
}

/// Why Jira refused the sign-in details when connecting (401), by what was chosen and what the server said.
/// Only the connect check (`JiraClient.testConnection`) throws these; later a 401 is `JiraError.unauthorized`.
public enum JiraSignInProblem: Error, Equatable, Sendable {
    /// Jira Cloud: the Atlassian account email + an API token (a password never works).
    case cloudNeedsAPIToken
    /// Data Center: the personal access token doesn't match.
    case tokenMismatch
    /// Data Center: username + password refused.
    case wrongPassword
    /// Data Center: username + password refused, and the server signs in through company SSO (Microsoft, Okta, SAML).
    case companySSO

    public static func classify(kind: JiraKind, method: JiraAuthMethod, sso: Bool) -> JiraSignInProblem {
        if kind == .cloud || method == .cloudApiToken { return .cloudNeedsAPIToken }
        if method == .pat { return .tokenMismatch }
        return sso ? .companySSO : .wrongPassword
    }
}

public struct JiraUser: Sendable, Hashable, Codable {
    /// Cloud accountId or DC username/key.
    public var id: String
    public var displayName: String
    public var email: String?
    public var timeZone: String?
}

public struct JiraIssue: Sendable, Hashable {
    public var id: String
    public var key: String
    public var summary: String
    public var issueType: String?
    public var statusName: String?
    public var statusCategory: StatusCategory
    public var parentKey: String?
    public var parentSummary: String?
    public var assigneeId: String?
    public var originalEstimateSeconds: Int?
    public var timeSpentSeconds: Int?
    public var updated: Date?
    public var projectKey: String
    public var projectName: String?

    public init(id: String, key: String, summary: String, issueType: String? = nil, statusName: String? = nil,
                statusCategory: StatusCategory = .indeterminate, parentKey: String? = nil, parentSummary: String? = nil,
                assigneeId: String? = nil, originalEstimateSeconds: Int? = nil, timeSpentSeconds: Int? = nil,
                updated: Date? = nil, projectKey: String? = nil, projectName: String? = nil) {
        self.id = id; self.key = key; self.summary = summary; self.issueType = issueType; self.statusName = statusName
        self.statusCategory = statusCategory; self.parentKey = parentKey; self.parentSummary = parentSummary
        self.assigneeId = assigneeId; self.originalEstimateSeconds = originalEstimateSeconds
        self.timeSpentSeconds = timeSpentSeconds; self.updated = updated
        self.projectKey = projectKey ?? Issue.projectKey(of: key); self.projectName = projectName
    }
}

public struct JiraWorklog: Sendable, Hashable {
    public var id: String
    public var issueId: String
    public var authorId: String
    public var started: Date
    public var timeSpentSeconds: Int
    /// Comment as plain text (ADF / wiki converted; bullet items on their own lines).
    public var comment: String
    public var updated: Date

    public init(id: String, issueId: String, authorId: String, started: Date, timeSpentSeconds: Int, comment: String, updated: Date) {
        self.id = id; self.issueId = issueId; self.authorId = authorId; self.started = started
        self.timeSpentSeconds = timeSpentSeconds; self.comment = comment; self.updated = updated
    }
}

/// What tikjot writes (§9.2): started, timeSpentSeconds, comment.
public struct WorklogDraft: Sendable, Hashable {
    public var started: Date
    public var timeSpentSeconds: Int
    /// Unique descriptions; 1 → plain text, ≥ 2 → bullet list (§9.3). Ignored when `commentOverride` is set.
    public var descriptions: [String]
    public var commentOverride: String?

    public init(started: Date, timeSpentSeconds: Int, descriptions: [String], commentOverride: String? = nil) {
        self.started = started; self.timeSpentSeconds = timeSpentSeconds
        self.descriptions = descriptions; self.commentOverride = commentOverride
    }

    /// The comment as plain text (what we compare against Jira).
    public var plainComment: String {
        if let o = commentOverride { return o }
        return CommentRenderer.plain(descriptions)
    }
}
