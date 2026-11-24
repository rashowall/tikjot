import Foundation

/// A Jira project found in imported worklogs that no project covers yet (§10.4). It waits — saved, so it survives a
/// restart — until you create a project for it or leave it out (onboarding Projects step, Connect another Jira step 2,
/// or the card at the top of Projects).
public struct ProjectSuggestion: Codable, Equatable, Sendable {
    public var key: String
    /// The Jira project's name (the proposed project name).
    public var name: String
    public var instanceId: UUID

    public init(key: String, name: String, instanceId: UUID) {
        self.key = key
        self.name = name
        self.instanceId = instanceId
    }
}

/// Pure logic of the project proposal list: pending suggestions (stored as a list) and what "Add" creates.
public enum ProjectProposals {
    /// Key-value store key of the pending suggestions.
    public static let storageKey = "pendingProjectSuggestions"

    /// Pending suggestions as stored: sorted by key, so the saved value is stable.
    public static func encode(_ pending: [String: (String, UUID)]) -> [ProjectSuggestion] {
        pending.map { ProjectSuggestion(key: $0.key, name: $0.value.0, instanceId: $0.value.1) }.sorted { $0.key < $1.key }
    }

    public static func decode(_ list: [ProjectSuggestion]) -> [String: (String, UUID)] {
        var out: [String: (String, UUID)] = [:]
        for s in list where out[s.key] == nil { out[s.key] = (s.name, s.instanceId) }
        return out
    }

    /// Adds the keys an import found without a project (key → Jira project name); a key already waiting keeps its entry.
    public static func merging(_ pending: [String: (String, UUID)], found: [String: String], instanceId: UUID) -> [String: (String, UUID)] {
        pending.merging(found.map { ($0.key, ($0.value, instanceId)) }) { a, _ in a }
    }

    /// One project to create from the list.
    public struct Plan: Equatable, Sendable {
        public var instanceId: UUID
        public var key: String
        public var name: String
        public var color: String
        public var billable: Bool
    }

    /// What "Add N projects" creates: every ticked row, in list order, with its shown colour; an empty name falls back
    /// to the key. Rows left out create nothing (their entries keep their task and still go to Jira, without a project).
    public static func plan(items: [(UUID, String)], colors: [String], names: [String: String],
                            leftOut: Set<String>, notBillable: Set<String>) -> [Plan] {
        items.enumerated().compactMap { i, item in
            guard !leftOut.contains(item.1) else { return nil }
            let n = (names[item.1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Plan(instanceId: item.0, key: item.1, name: n.isEmpty ? item.1 : n,
                        color: i < colors.count ? colors[i] : ProjectPalette.nextUnused(colors), billable: !notBillable.contains(item.1))
        }
    }
}
