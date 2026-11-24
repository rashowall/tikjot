import Foundation
import TikjotDomain

/// "What are you working on?" (Toggl pattern): what you did before, as description + task in one suggestion.
/// Empty query → your most recent combinations; typing → entries whose description is like the text
/// (start of the description first, then start of a word, then anywhere; task key/name as a weaker hint),
/// ranked by how often and how recently you used them. Duplicates (same text + task + project) merge.
public enum DescriptionSuggestions {
    public struct Suggestion: Sendable, Hashable, Identifiable {
        public var id: String { "\(description.lowercased())|\(instanceId?.uuidString ?? "")|\(issueId ?? "")|\(projectId?.uuidString ?? "")" }
        public let description: String
        public let instanceId: UUID?
        public let issueId: String?
        public let projectId: UUID?
        public let lastUsed: Date
        public let count: Int
    }

    public static func suggest(entries: [TimeEntry], issues: [Issue] = [], query: String, now: Date,
                               days: Int = 60, limit: Int = 5) -> [Suggestion] {
        let since = now.addingTimeInterval(-Double(days) * 86400)
        var groups: [String: (s: TimeEntry, last: Date, count: Int)] = [:]
        for e in entries where e.kind == .work && e.deletedAt == nil && e.start >= since {
            let d = e.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !d.isEmpty else { continue }
            let key = "\(d.lowercased())|\(e.instanceId?.uuidString ?? "")|\(e.issueId ?? "")|\(e.projectId?.uuidString ?? "")"
            if let g = groups[key] {
                groups[key] = (e.start > g.last ? e : g.s, max(g.last, e.start), g.count + 1)
            } else {
                groups[key] = (e, e.start, 1)
            }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let issueText = Dictionary(issues.map { ("\($0.instanceId.uuidString)|\($0.issueId)", "\($0.key) \($0.summary)".lowercased()) }, uniquingKeysWith: { a, _ in a })
        func match(_ e: TimeEntry) -> Double? {
            guard !q.isEmpty else { return 1 }
            let d = e.description.lowercased()
            if d.hasPrefix(q) { return 4 }
            if d.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 3 }
            if d.contains(q) { return 2 }
            if let i = e.issueId, let iid = e.instanceId, issueText["\(iid.uuidString)|\(i)"]?.contains(q) == true { return 1 }
            return nil
        }
        let scored: [(Suggestion, Double)] = groups.values.compactMap { g in
            guard let m = match(g.s) else { return nil }
            let ageDays = max(0, now.timeIntervalSince(g.last) / 86400)
            let usage = log2(Double(g.count) + 1) * pow(0.5, ageDays / 14)   // frequency × recency (14-day half-life)
            let score = q.isEmpty ? -ageDays : m * 10 + usage
            let s = Suggestion(description: g.s.description.trimmingCharacters(in: .whitespacesAndNewlines),
                               instanceId: g.s.instanceId, issueId: g.s.issueId, projectId: g.s.projectId,
                               lastUsed: g.last, count: g.count)
            return (s, score)
        }
        // An exact match of what you typed sorts first (it is the entry you mean).
        return scored.sorted { a, b in
            let ea = a.0.description.lowercased() == q, eb = b.0.description.lowercased() == q
            if ea != eb { return ea }
            return a.1 != b.1 ? a.1 > b.1 : a.0.lastUsed > b.0.lastUsed
        }.prefix(limit).map(\.0)
    }
}
