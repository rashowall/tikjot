import Foundation
import TikjotDomain

/// Smart task list without typing (§10.1) and local search (§10.2).
public struct SuggestionEngine: Sendable {
    public struct Weights: Sendable {
        /// Half-life of the recency decay (§20.2: tune with real data).
        public var halfLifeDays: Double = 14
        public var usagePerHour: Double = 1.0
        public var assigned: Double = 2.0
        public var assignedRecent: Double = 1.5
        public var today: Double = 6.0
        public var donePenalty: Double = 0.25
        public var filterBoost: Double = 1.5
        public init() {}
    }

    public var weights = Weights()
    public init(weights: Weights = Weights()) { self.weights = weights }

    public struct Candidate: Sendable, Identifiable, Hashable {
        public var id: String { issue.id }
        public let issue: Issue
        public let score: Double
        /// Own earlier descriptions for this task, newest first (picker groups them under the task).
        public let recentDescriptions: [String]
        public let lastUsed: Date?
        /// Own use alone: hours × recency decay, without the assignment / today / done adjustments of `score`.
        public let usage: Double

        public init(issue: Issue, score: Double, recentDescriptions: [String] = [], lastUsed: Date? = nil, usage: Double = 0) {
            self.issue = issue; self.score = score; self.recentDescriptions = recentDescriptions
            self.lastUsed = lastUsed; self.usage = usage
        }

        /// The user worked on it: own entries here, or own worklogs found in Jira (closed tasks included).
        public var isLogged: Bool { lastUsed != nil || issue.sources.contains("logged") }
    }

    /// Score every cached issue from usage (frequency × recency), assignment and today's use.
    public func score(issues: [Issue], entries: [TimeEntry], archivedProjectKeys: Set<String> = [], now: Date, calendar: Calendar) -> [Candidate] {
        let today = LocalDate(now, calendar: calendar)
        var usage: [IssueRef: (score: Double, today: Bool, last: Date, descs: [String])] = [:]
        let lambda = log(2) / (weights.halfLifeDays * 86_400)
        for e in entries.sorted(by: { $0.start > $1.start }) {
            guard let ref = e.issueRef else { continue }
            let hours = Double(e.duration(now: now)) / 3600
            let age = max(0, now.timeIntervalSince(e.start))
            var u = usage[ref] ?? (0, false, e.start, [])
            u.score += (weights.usagePerHour * max(0.25, hours)) * exp(-lambda * age)
            if LocalDate(e.start, calendar: calendar) == today { u.today = true }
            u.last = max(u.last, e.start)
            let d = e.description.trimmingCharacters(in: .whitespaces)
            if !d.isEmpty && !u.descs.contains(d) && u.descs.count < 5 { u.descs.append(d) }
            usage[ref] = u
        }
        return issues.compactMap { i in
            guard i.availability == .ok else { return nil }
            if archivedProjectKeys.contains("\(i.instanceId.uuidString)|\(i.projectKey)") { return nil }
            let ref = IssueRef(instanceId: i.instanceId, issueId: i.issueId)
            let u = usage[ref]
            var s = u?.score ?? 0
            if i.assignedToMe && !i.isDone {
                s += weights.assigned
                if let up = i.updated, now.timeIntervalSince(up) < 7 * 86_400 { s += weights.assignedRecent }
            }
            if u?.today == true { s += weights.today }
            if i.sources.contains(where: { $0.hasPrefix("filter:") }) { s += 0.01 } // tie-break only; boosted in search
            if i.isDone { s *= weights.donePenalty }
            return Candidate(issue: i, score: s, recentDescriptions: u?.descs ?? [], lastUsed: u?.last, usage: u?.score ?? 0)
        }
    }

    /// The list shown without typing: pinned first (user order), then best scores, max `limit`.
    public func suggestions(issues: [Issue], entries: [TimeEntry], archivedProjectKeys: Set<String> = [], now: Date, calendar: Calendar, limit: Int = 10) -> [Candidate] {
        top(score(issues: issues, entries: entries, archivedProjectKeys: archivedProjectKeys, now: now, calendar: calendar), limit: limit)
    }

    /// The unsearched list from already scored candidates: pinned first (user order), then best scores.
    public func top(_ scored: [Candidate], limit: Int = 10) -> [Candidate] {
        let pinned = scored.filter(\.issue.pinned).sorted { $0.issue.pinOrder < $1.issue.pinOrder }
        let rest = scored.filter { !$0.issue.pinned && $0.score > 0 }.sorted { $0.score > $1.score }
        return Array((pinned + rest).prefix(max(limit, pinned.count)))
    }

    /// Local search in one list: match strength (key, project key, key prefix, words), then score (§10.2).
    /// Words match only where a word starts — no scattered letters, no hits in the middle of a word.
    public func search(_ query: String, candidates: [Candidate], projectNames: [String: String] = [:], limit: Int = 30) -> [Candidate] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return candidates.sorted { $0.score > $1.score } }
        let hits = candidates.compactMap { c -> (c: Candidate, m: Int, s: Double)? in
            Self.matchStrength(q, c, projectNames: projectNames).map { (c, $0, c.score + Self.filterBoost(c.issue)) }
        }
        return hits.sorted { ($0.m, $0.s) > ($1.m, $1.s) }.prefix(limit).map(\.c)
    }

    // MARK: Ranked picker (§10.2)

    /// The picker's sections for a typed query.
    public struct Ranked: Sendable, Equatable {
        /// Tasks you logged (closed ones too): match strength, then how often × how recently.
        public var logged: [Candidate] = []
        /// Assigned to you, not done.
        public var assigned: [Candidate] = []
        /// Everything else Jira knows — other people's issues, shown muted below.
        public var more: [Candidate] = []
        public init() {}
    }

    /// One ranked list in three sections: 1) you logged, 2) assigned to you, 3) more in Jira. Pinned tasks win ties.
    /// `remote` is Jira's answer to the same query, in Jira's order. Its issues stay even where the local word match
    /// misses them (Jira also reads descriptions), below every local match of their section.
    public func rank(_ query: String, candidates: [Candidate], remote: [Issue] = [], projectNames: [String: String] = [:],
                     limit: Int = 8) -> Ranked {
        var r = Ranked()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return r }
        let remotePos = Dictionary(remote.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let known = Set(candidates.map(\.id))
        let all = candidates + remote.filter { !known.contains($0.id) }.map { Candidate(issue: $0, score: 0) }
        var logged: [(c: Candidate, m: Int)] = [], assigned: [(c: Candidate, m: Int)] = [], more: [(c: Candidate, m: Int)] = []
        for c in all {
            guard let m = Self.matchStrength(q, c, projectNames: projectNames) ?? (remotePos[c.id] != nil ? 0 : nil) else { continue }
            if c.isLogged { logged.append((c, m)) }
            else if c.issue.assignedToMe && !c.issue.isDone { assigned.append((c, m)) }
            else { more.append((c, m)) }
        }
        // Within a section a pinned task wins a tie of match strength; a stronger match still goes first (beta 2026-10-21).
        r.logged = logged.sorted { a, b in
            if a.m != b.m { return a.m > b.m }
            if a.c.issue.pinned != b.c.issue.pinned { return a.c.issue.pinned }
            if a.c.usage != b.c.usage { return a.c.usage > b.c.usage }
            return (a.c.lastUsed ?? .distantPast) > (b.c.lastUsed ?? .distantPast)
        }.prefix(limit).map(\.c)
        r.assigned = assigned.sorted { ($0.m, $0.c.issue.pinned ? 1 : 0, $0.c.score + Self.filterBoost($0.c.issue))
            > ($1.m, $1.c.issue.pinned ? 1 : 0, $1.c.score + Self.filterBoost($1.c.issue)) }
            .prefix(limit).map(\.c)
        r.more = more.sorted { a, b in
            if a.m != b.m { return a.m > b.m }
            if a.c.issue.pinned != b.c.issue.pinned { return a.c.issue.pinned }
            let pa = remotePos[a.c.id] ?? .max, pb = remotePos[b.c.id] ?? .max
            if pa != pb { return pa < pb }
            return a.c.score + Self.filterBoost(a.c.issue) > b.c.score + Self.filterBoost(b.c.issue)
        }.prefix(limit).map(\.c)
        return r
    }

    /// Tasks whose own earlier descriptions share words with `description` ("Used with similar descriptions"):
    /// the biggest share of the description's words first, ties by how often × how recently.
    public func similar(to description: String, candidates: [Candidate], entries: [TimeEntry], limit: Int = 3) -> [Candidate] {
        let want = Set(Self.words(description).filter { $0.count >= 3 && !Self.stopWords.contains($0) })
        guard !want.isEmpty else { return [] }
        var best: [IssueRef: Double] = [:]
        for e in entries {
            guard let ref = e.issueRef, !e.description.isEmpty else { continue }
            let shared = want.intersection(Self.words(e.description)).count
            guard shared > 0 else { continue }
            best[ref] = max(best[ref] ?? 0, Double(shared) / Double(want.count))
        }
        guard !best.isEmpty else { return [] }
        let hits = candidates.compactMap { c -> (c: Candidate, share: Double)? in
            best[IssueRef(instanceId: c.issue.instanceId, issueId: c.issue.issueId)].map { (c, $0) }
        }
        return hits.sorted { ($0.share, $0.c.usage) > ($1.share, $1.c.usage) }.prefix(limit).map(\.c)
    }

    // MARK: Matching

    /// How strongly a task matches what was typed (higher = stronger), nil = not at all.
    /// 6 exact key · 5 project key ("WEB") · 4 key prefix ("WEB-1") · 3 every word starts a word of the name ·
    /// 2 … of the name, parent, project or key · 1 … counting own earlier descriptions too.
    static func matchStrength(_ query: String, _ c: Candidate, projectNames: [String: String]) -> Int? {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return nil }
        let key = fold(c.issue.key)
        if key == q { return 6 }
        if fold(c.issue.projectKey) == q { return 5 }
        if key.hasPrefix(q) { return 4 }
        let want = words(q)
        guard !want.isEmpty else { return nil }
        func covers(_ texts: [String]) -> Bool {
            let have = texts.flatMap { words($0) }
            return want.allSatisfy { w in have.contains { $0.hasPrefix(w) } }
        }
        let name = [c.issue.summary]
        if covers(name) { return 3 }
        let task = name + [c.issue.parentSummary ?? "", c.issue.parentKey ?? "", c.issue.key,
                           projectNames[c.issue.projectKey] ?? "", c.issue.projectName ?? ""]
        if covers(task) { return 2 }
        if covers(task + c.recentDescriptions) { return 1 }
        return nil
    }

    /// Case- and accent-insensitive ("ucet" finds "Účet").
    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// Folded words: letters and digits, split at everything else ("WEB-142" → "web", "142").
    static func words(_ s: String) -> [String] { fold(s).split { !$0.isLetter && !$0.isNumber }.map(String.init) }

    /// Too common to make two descriptions "similar".
    static let stopWords: Set<String> = ["the", "and", "for", "with", "from", "into", "pre", "pri", "ako", "alebo", "pod", "nad", "cez"]

    /// Saved filters / JQL sources (§6.10): boosted within the same match strength.
    static func filterBoost(_ i: Issue) -> Double { i.sources.contains { $0.hasPrefix("filter:") } ? 20 : 0 }
}
