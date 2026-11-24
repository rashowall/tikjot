import Foundation
import TikjotDomain

/// An in-memory Jira (Cloud v3 or DC v2) behind `HTTPTransport`. Used by tests, UI tests and demo mode.
/// Understands the JQL tikjot sends (worklogAuthor, updated, assignee, key, text, issueId in, project, statusCategory).
public actor MockJiraServer: HTTPTransport {
    public struct MockIssue: Sendable {
        public var id: String
        public var key: String
        public var summary: String
        public var type = "Task"
        public var status = "In Progress"
        public var statusCategory = "indeterminate"
        public var parentKey: String?
        public var parentSummary: String?
        public var assignee: String?
        public var estimate: Int?
        public var projectName: String?
        public var updated: Date
        /// Issues the user can't log on (e.g. closed with a workflow that forbids logging).
        public var rejectWorklogs: String?

        public init(id: String, key: String, summary: String, type: String = "Task", status: String = "In Progress",
                    statusCategory: String = "indeterminate", parentKey: String? = nil, parentSummary: String? = nil,
                    assignee: String? = nil, estimate: Int? = nil, projectName: String? = nil,
                    updated: Date = Date(), rejectWorklogs: String? = nil) {
            self.id = id; self.key = key; self.summary = summary; self.type = type; self.status = status
            self.statusCategory = statusCategory; self.parentKey = parentKey; self.parentSummary = parentSummary
            self.assignee = assignee; self.estimate = estimate; self.projectName = projectName
            self.updated = updated; self.rejectWorklogs = rejectWorklogs
        }
    }

    public struct MockWorklog: Sendable {
        public var id: String
        public var issueId: String
        public var author: String
        public var started: Date
        public var seconds: Int
        public var comment: String
        public var updated: Date
    }

    public let kind: JiraKind
    public var me: String
    public var meName: String
    public var timeZone: String
    public private(set) var issues: [String: MockIssue] = [:]
    public private(set) var worklogs: [String: MockWorklog] = [:]
    public private(set) var requestLog: [String] = []
    /// Every JQL query searched, in order (the request log has only method + path).
    public private(set) var jqlLog: [String] = []
    public var filters: [String: (name: String, jql: String)] = [:]
    /// Accepted secret; anything else → 401.
    public var validSecret: String
    public var offline = false
    /// Status codes returned (once each) before handling requests normally.
    public var injectedStatuses: [(Int, [String: String])] = []
    /// When set, every request gets this HTML page (simulates an SSO proxy in front of Jira).
    public var signInPageHTML: String?
    /// Requests (by method, e.g. "POST") that are carried out but whose answer is lost (timeout after Jira saved it).
    public var loseResponses: [String] = []
    public func loseNextResponse(method: String) { loseResponses.append(method) }
    public func setSignInPage(_ html: String?) { signInPageHTML = html }
    private var nextWorklogId = 10_000
    private let baseClock: @Sendable () -> Date
    private var fixedNow: Date?
    private func clock() -> Date { fixedNow ?? baseClock() }
    /// Pins the server's clock (tests).
    public func setNow(_ d: Date?) { fixedNow = d }

    public init(kind: JiraKind, me: String = "me", meName: String = "Martin Example", timeZone: String = "Europe/Bratislava",
                validSecret: String = "secret", clock: @escaping @Sendable () -> Date = { Date() }) {
        self.kind = kind
        self.me = me
        self.meName = meName
        self.timeZone = timeZone
        self.validSecret = validSecret
        self.baseClock = clock
    }

    // MARK: Setup

    public func add(_ issue: MockIssue) { issues[issue.id] = issue }

    @discardableResult
    public func addWorklog(issueId: String, author: String? = nil, started: Date, seconds: Int, comment: String = "", updated: Date? = nil) -> String {
        nextWorklogId += 1
        let id = "\(nextWorklogId)"
        worklogs[id] = MockWorklog(id: id, issueId: issueId, author: author ?? me, started: started, seconds: seconds, comment: comment, updated: updated ?? clock())
        issues[issueId]?.updated = clock()
        return id
    }

    public func editWorklog(_ id: String, seconds: Int? = nil, comment: String? = nil, started: Date? = nil) {
        guard var w = worklogs[id] else { return }
        if let seconds { w.seconds = seconds }
        if let comment { w.comment = comment }
        if let started { w.started = started }
        w.updated = clock().addingTimeInterval(1)
        worklogs[id] = w
        issues[w.issueId]?.updated = w.updated
    }

    public func removeWorklog(_ id: String) {
        if let w = worklogs.removeValue(forKey: id) { issues[w.issueId]?.updated = clock() }
    }

    public func removeIssue(id: String) { issues[id] = nil }
    /// Tasks the search index doesn't know yet (Data Center reindexing, just created): search leaves them out,
    /// `GET issue/{id}` still returns them.
    public var unindexed: Set<String> = []
    public func setUnindexed(_ ids: Set<String>) { unindexed = ids }
    public func moveIssue(id: String, newKey: String) { issues[id]?.key = newKey; issues[id]?.updated = clock() }
    public func setOffline(_ v: Bool) { offline = v }
    public func setTimeZone(_ id: String) { timeZone = id }
    public func inject(status: Int, headers: [String: String] = [:]) { injectedStatuses.append((status, headers)) }
    public func setFilter(id: String, name: String, jql: String) { filters[id] = (name, jql) }
    public func setValidSecret(_ s: String) { validSecret = s }
    public func setRejectWorklogs(issueId: String, message: String?) { issues[issueId]?.rejectWorklogs = message }
    public func clearLog() { requestLog = []; jqlLog = [] }

    public func myWorklogs() -> [MockWorklog] { worklogs.values.filter { $0.author == me }.sorted { $0.started < $1.started } }

    // MARK: Transport

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try handle(request)
        if let i = loseResponses.firstIndex(of: request.httpMethod ?? "GET") {
            loseResponses.remove(at: i)
            throw JiraError.outcomeUnknown
        }
        return result
    }

    private func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        requestLog.append("\(method) \(url.path)")
        if offline { throw JiraError.offline }
        if let html = signInPageHTML {
            return (Data(html.utf8), response(url, 200, ["Content-Type": "text/html; charset=utf-8"]))
        }
        if !injectedStatuses.isEmpty {
            let (code, headers) = injectedStatuses.removeFirst()
            return (Data("{\"errorMessages\":[\"Injected \(code)\"]}".utf8), response(url, code, headers))
        }
        // Answered without signing in, like Jira (the connect form asks it to set Cloud / Data Center).
        if method == "GET", url.path.hasSuffix("/rest/api/2/serverInfo") {
            return json(url, ["deploymentType": kind == .cloud ? "Cloud" : "DataCenter", "version": kind == .cloud ? "1001.0.0" : "9.12.0"])
        }
        guard authorized(request) else { return (Data(), response(url, 401)) }

        let api = kind == .cloud ? "/rest/api/3" : "/rest/api/2"
        var path = url.path
        guard path.hasPrefix(api) else { return (Data(), response(url, 404)) }
        path.removeFirst(api.count)
        let parts = path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        switch (method, parts.count, parts.first) {
        case ("GET", 1, "myself"):
            var o: [String: Any] = ["displayName": meName, "timeZone": timeZone, "emailAddress": "\(me)@example.com"]
            if kind == .cloud { o["accountId"] = me } else { o["name"] = me; o["key"] = me }
            return json(url, o)
        case ("POST", _, "search"):
            // Like Jira: an unknown id in "issueId in (…)" fails the whole query.
            if let missing = unknownIssueId(in: body["jql"] as? String ?? "") {
                return json(url, ["errorMessages": ["An issue with key '\(missing)' does not exist for field 'issueId'."]], status: 400)
            }
            let all = try search(jql: body["jql"] as? String ?? "").filter { !unindexed.contains($0.id) }
            let max = body["maxResults"] as? Int ?? 50
            if kind == .cloud {
                let start = Int(body["nextPageToken"] as? String ?? "0") ?? 0
                let page = Array(all.dropFirst(start).prefix(max))
                let isLast = start + page.count >= all.count
                var o: [String: Any] = ["issues": page.map(issueJSON), "isLast": isLast]
                if !isLast { o["nextPageToken"] = "\(start + page.count)" }
                return json(url, o)
            } else {
                let start = body["startAt"] as? Int ?? 0
                let page = Array(all.dropFirst(start).prefix(max))
                return json(url, ["issues": page.map(issueJSON), "total": all.count, "startAt": start, "maxResults": max])
            }
        case ("GET", 2, "issue"):
            guard let i = find(parts[1]) else { return (Data(), response(url, 404)) }
            return json(url, issueJSON(i))
        case ("GET", 3, "issue") where parts[2] == "worklog":
            guard let i = find(parts[1]) else { return (Data(), response(url, 404)) }
            var ws = worklogs.values.filter { $0.issueId == i.id }.sorted { $0.started < $1.started }
            if let after = query.first(where: { $0.name == "startedAfter" })?.value.flatMap(Double.init) {
                ws = ws.filter { $0.started.timeIntervalSince1970 * 1000 >= after }
            }
            let start = Int(query.first { $0.name == "startAt" }?.value ?? "0") ?? 0
            let max = Int(query.first { $0.name == "maxResults" }?.value ?? "1000") ?? 1000
            let page = Array(ws.dropFirst(start).prefix(max))
            return json(url, ["worklogs": page.map(worklogJSON), "total": ws.count, "startAt": start, "maxResults": max])
        case ("GET", 4, "issue") where parts[2] == "worklog":
            guard find(parts[1]) != nil, let w = worklogs[parts[3]] else { return (Data(), response(url, 404)) }
            return json(url, worklogJSON(w))
        case ("POST", 3, "issue") where parts[2] == "worklog":
            guard let i = find(parts[1]) else { return (Data(), response(url, 404)) }
            if let reject = i.rejectWorklogs { return json(url, ["errorMessages": [reject]], status: 400) }
            guard let w = parseDraft(body, issueId: i.id, id: nil) else { return json(url, ["errorMessages": ["Bad worklog"]], status: 400) }
            worklogs[w.id] = w
            issues[i.id]?.updated = clock()
            return json(url, worklogJSON(w), status: 201)
        case ("PUT", 4, "issue") where parts[2] == "worklog":
            guard let i = find(parts[1]), let old = worklogs[parts[3]] else { return (Data(), response(url, 404)) }
            if let reject = i.rejectWorklogs { return json(url, ["errorMessages": [reject]], status: 400) }
            guard old.author == me else { return json(url, ["errorMessages": ["Not your worklog"]], status: 403) }
            guard var w = parseDraft(body, issueId: i.id, id: old.id) else { return json(url, ["errorMessages": ["Bad worklog"]], status: 400) }
            w.author = old.author
            worklogs[w.id] = w
            return json(url, worklogJSON(w))
        case ("DELETE", 4, "issue") where parts[2] == "worklog":
            guard worklogs[parts[3]] != nil else { return (Data(), response(url, 404)) }
            worklogs[parts[3]] = nil
            return (Data(), response(url, 204))
        case ("GET", 2, "filter"):
            guard let f = filters[parts[1]] else { return (Data(), response(url, 404)) }
            return json(url, ["id": parts[1], "name": f.name, "jql": f.jql])
        default:
            return (Data(), response(url, 404))
        }
    }

    // MARK: Helpers

    private func authorized(_ r: URLRequest) -> Bool {
        guard let h = r.value(forHTTPHeaderField: "Authorization") else { return false }
        if h.hasPrefix("Bearer ") { return String(h.dropFirst(7)) == validSecret }
        if h.hasPrefix("Basic "), let d = Data(base64Encoded: String(h.dropFirst(6))), let s = String(data: d, encoding: .utf8) {
            return s.split(separator: ":", maxSplits: 1).last.map(String.init) == validSecret
        }
        return false
    }

    private func find(_ keyOrId: String) -> MockIssue? {
        issues[keyOrId] ?? issues.values.first { $0.key.caseInsensitiveCompare(keyOrId) == .orderedSame }
    }

    private func response(_ url: URL, _ code: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private func json(_ url: URL, _ o: Any, status: Int = 200) -> (Data, HTTPURLResponse) {
        ((try? JSONSerialization.data(withJSONObject: o)) ?? Data(), response(url, status, ["Content-Type": "application/json"]))
    }

    private func issueJSON(_ i: MockIssue) -> [String: Any] {
        let spent = worklogs.values.filter { $0.issueId == i.id }.reduce(0) { $0 + $1.seconds }
        var f: [String: Any] = [
            "summary": i.summary,
            "status": ["name": i.status, "statusCategory": ["key": i.statusCategory]],
            "issuetype": ["name": i.type],
            "updated": JiraDate.format(i.updated),
            "project": ["key": Issue.projectKey(of: i.key), "name": i.projectName ?? Issue.projectKey(of: i.key)],
            "timespent": spent,
        ]
        if let e = i.estimate { f["timeoriginalestimate"] = e }
        if let p = i.parentKey { f["parent"] = ["key": p, "fields": ["summary": i.parentSummary ?? p]] }
        if let a = i.assignee { f["assignee"] = kind == .cloud ? ["accountId": a] : ["name": a] }
        return ["id": i.id, "key": i.key, "fields": f]
    }

    private func worklogJSON(_ w: MockWorklog) -> [String: Any] {
        let comment: Any = kind == .cloud ? CommentRenderer.adf(w.comment) : CommentRenderer.wiki(w.comment)
        return [
            "id": w.id, "issueId": w.issueId,
            "author": kind == .cloud ? ["accountId": w.author] : ["name": w.author, "key": w.author],
            "started": JiraDate.format(w.started), "timeSpentSeconds": w.seconds,
            "comment": comment, "updated": JiraDate.format(w.updated),
        ]
    }

    private func parseDraft(_ body: [String: Any], issueId: String, id: String?) -> MockWorklog? {
        guard let s = body["started"] as? String, let started = JiraDate.parse(s), let secs = body["timeSpentSeconds"] as? Int, secs > 0 else { return nil }
        let comment = kind == .cloud ? CommentRenderer.plain(fromADF: body["comment"]) : CommentRenderer.plain(fromWiki: body["comment"] as? String ?? "")
        let wid: String
        if let id { wid = id } else { nextWorklogId += 1; wid = "\(nextWorklogId)" }
        return MockWorklog(id: wid, issueId: issueId, author: me, started: started, seconds: secs, comment: comment, updated: clock())
    }

    // MARK: JQL (subset)

    private func search(jql: String) throws -> [MockIssue] {
        jqlLog.append(jql)
        var clauses = jql
        if let r = clauses.range(of: "ORDER BY", options: .caseInsensitive) { clauses = String(clauses[..<r.lowerBound]) }
        let ands = clauses.components(separatedBy: " AND ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var result = Array(issues.values)
        for c in ands {
            result = result.filter { matches($0, clause: c) }
        }
        return result.sorted { $0.updated > $1.updated }
    }

    private func unknownIssueId(in jql: String) -> String? {
        guard jql.lowercased().hasPrefix("issueid in"), let open = jql.firstIndex(of: "("), let close = jql.firstIndex(of: ")") else { return nil }
        let ids = jql[jql.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return ids.first { issues[$0] == nil }
    }

    private func value(_ c: String, after op: String) -> String {
        guard let r = c.range(of: op) else { return "" }
        return c[r.upperBound...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private func matches(_ i: MockIssue, clause raw: String) -> Bool {
        var c = raw
        if c.hasPrefix("(") && c.hasSuffix(")") { c = String(c.dropFirst().dropLast()) }
        if c.contains(" OR ") {
            return c.components(separatedBy: " OR ").contains { matches(i, clause: $0.trimmingCharacters(in: .whitespaces)) }
        }
        let lower = c.lowercased()
        if lower.hasPrefix("worklogauthor") {
            // "= currentUser()" (what tikjot sends) or a named author.
            let v = value(c, after: "=")
            let author = v.isEmpty || v.lowercased() == "currentuser()" ? me : v
            return worklogs.values.contains { $0.issueId == i.id && $0.author == author }
        }
        if lower.hasPrefix("assignee") { return i.assignee == me }
        if lower.hasPrefix("updated") {
            let v = value(c, after: ">=")
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            // Jira reads JQL dates in the user's profile time zone.
            df.timeZone = TimeZone(identifier: timeZone) ?? .current
            df.dateFormat = v.contains(":") ? "yyyy/MM/dd HH:mm" : "yyyy-MM-dd"
            guard let d = df.date(from: v) ?? { df.dateFormat = "yyyy/MM/dd"; return df.date(from: v) }() else { return true }
            return i.updated >= d
        }
        if lower.hasPrefix("key ="), !lower.contains(" in ") { return i.key.caseInsensitiveCompare(value(c, after: "=")) == .orderedSame }
        if lower.hasPrefix("issuekey ="), !lower.contains(" in ") { return i.key.caseInsensitiveCompare(value(c, after: "=")) == .orderedSame }
        if lower.hasPrefix("text ~") || lower.hasPrefix("summary ~") {
            let words = value(c, after: "~").lowercased().replacingOccurrences(of: "*", with: "").split(separator: " ")
            return words.allSatisfy { i.summary.lowercased().contains($0) || i.key.lowercased().contains($0) }
        }
        if lower.hasPrefix("issueid in") || lower.hasPrefix("id in") || lower.hasPrefix("key in") || lower.hasPrefix("issuekey in") {
            guard let open = c.firstIndex(of: "("), let close = c.lastIndex(of: ")") else { return false }
            let ids = c[c.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            return ids.contains(i.id) || ids.contains { $0.caseInsensitiveCompare(i.key) == .orderedSame }
        }
        if lower.hasPrefix("project =") || lower.hasPrefix("project=") {
            return Issue.projectKey(of: i.key).caseInsensitiveCompare(value(c, after: "=")) == .orderedSame
        }
        if lower.hasPrefix("statuscategory !=") {
            return i.statusCategory.lowercased() != value(c, after: "!=").lowercased().replacingOccurrences(of: " ", with: "")
        }
        if lower.hasPrefix("resolution = unresolved") { return i.statusCategory != "done" }
        // Unknown clause (e.g. from a user filter) — don't filter.
        return true
    }
}
