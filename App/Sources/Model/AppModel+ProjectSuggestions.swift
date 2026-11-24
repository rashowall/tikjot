import Foundation
import SyncEngine
import TikjotDomain
import TikjotPersistence

/// Jira projects found in imported worklogs that no project covers yet (§10.4): saved pending suggestions and the
/// proposal list's "Add" (onboarding Projects step, Connect another Jira step 2, the Projects-tab card).
extension AppModel {
    func loadPendingProjectSuggestions() {
        guard let list = try? db.value([ProjectSuggestion].self, forKey: ProjectProposals.storageKey) else { return }
        pendingProjectSuggestions = ProjectProposals.decode(list)
    }

    func savePendingProjectSuggestions() {
        try? db.setValue(ProjectProposals.encode(pendingProjectSuggestions), forKey: ProjectProposals.storageKey)
    }

    /// Keeps what an import found without a project, so it can be offered (and survives a restart).
    func noteUnmappedKeys(_ found: [String: String], instanceId: UUID) {
        guard !found.isEmpty else { return }
        pendingProjectSuggestions = ProjectProposals.merging(pendingProjectSuggestions, found: found, instanceId: instanceId)
    }

    /// Imports one connection's worklogs from its history start (Connect another Jira, "Import history from"),
    /// with progress in `refreshing`; keys without a project become pending suggestions.
    func importHistory(instanceId: UUID) async throws -> RefreshReport {
        refreshing = (0, 1)
        defer { refreshing = nil }
        let r = try await engine.refresh(instanceId: instanceId) { p in
            Task { @MainActor in if case .issues(let d, let t) = p { self.refreshing = (d, max(t, 1)) } }
        }
        markReachable(instanceId)
        noteUnmappedKeys(r.unmappedKeys, instanceId: instanceId)
        return r
    }

    /// The proposal rows of one connection (nil: all), sorted by key.
    func proposalItems(instanceId: UUID? = nil) -> [(UUID, String)] {
        unmappedKeys().filter { instanceId == nil || $0.0 == instanceId }
    }

    /// The palette colours the proposed projects get, in row order (as `createProject` would pick them).
    func proposalColors(for items: [(UUID, String)]) -> [String] {
        var used = data.projects.map(\.color)
        return items.map { _ in let c = ProjectPalette.nextUnused(used); used.append(c); return c }
    }

    /// "Add N projects": creates the ticked rows; every shown row stops waiting (left out = no project — its entries
    /// keep their task, and starting a timer on such a task creates the project later).
    @discardableResult
    func createProposedProjects(_ items: [(UUID, String)], choices: ProjectProposalChoices) -> Int {
        let plans = ProjectProposals.plan(items: items, colors: proposalColors(for: items), names: choices.names,
                                          leftOut: choices.leftOut, notBillable: choices.notBillable)
        for p in plans { _ = createProject(name: p.name, color: p.color, billable: p.billable, keys: [(p.instanceId, p.key)]) }
        let shown = Set(items.map(\.1))
        pendingProjectSuggestions = pendingProjectSuggestions.filter { k, v in
            !shown.contains(k) && !data.rules.contains { $0.instanceId == v.1 && $0.value == k }
        }
        return plans.count
    }
}
