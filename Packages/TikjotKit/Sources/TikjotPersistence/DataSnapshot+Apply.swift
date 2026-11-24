import Foundation
import TikjotDomain

extension DataSnapshot {
    /// Mirrors `AppDatabase.apply` in memory, so the app doesn't reload everything after each write.
    public mutating func apply(_ c: Changes) {
        Self.merge(&instances, upsert: c.upsertInstances, delete: c.deleteInstances)
        if !c.deleteInstances.isEmpty {
            let gone = Set(c.deleteInstances)
            issues.removeAll { gone.contains($0.instanceId) }
        }
        Self.merge(&projects, upsert: c.upsertProjects, delete: c.deleteProjects)
        var rulesDelete = c.deleteRules
        for r in c.upsertRules {
            rulesDelete += rules.filter { $0.type == r.type && $0.instanceId == r.instanceId && $0.value == r.value && $0.id != r.id }.map(\.id)
        }
        Self.merge(&rules, upsert: c.upsertRules, delete: rulesDelete)
        for i in c.upsertIssues {
            if let idx = issues.firstIndex(where: { $0.instanceId == i.instanceId && $0.issueId == i.issueId }) { issues[idx] = i } else { issues.append(i) }
        }
        Self.merge(&entries, upsert: c.upsertEntries, delete: c.deleteEntries)
        entries.sort { $0.start < $1.start }
        Self.merge(&groups, upsert: c.upsertGroups, delete: c.deleteGroups)
        Self.merge(&schedule, upsert: c.upsertSchedule, delete: c.deleteSchedule)
        Self.merge(&customDays, upsert: c.upsertCustomDays, delete: c.deleteCustomDays)
        Self.merge(&absenceTypes, upsert: c.upsertAbsenceTypes, delete: [])
        Self.merge(&absences, upsert: c.upsertAbsences, delete: c.deleteAbsences)
        Self.merge(&suggestionSources, upsert: c.upsertSuggestionSources, delete: c.deleteSuggestionSources)
        if let s = c.settings { settings = s }
    }

    static func merge<T: Identifiable>(_ arr: inout [T], upsert: [T], delete: [T.ID]) where T.ID: Hashable {
        if !delete.isEmpty {
            let d = Set(delete)
            arr.removeAll { d.contains($0.id) }
        }
        guard !upsert.isEmpty else { return }
        var index = Dictionary(arr.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        for x in upsert {
            if let i = index[x.id] { arr[i] = x } else { index[x.id] = arr.count; arr.append(x) }
        }
    }

    /// The inverse of `c` against the current state (for undo). Covers everything except settings and issues.
    public func inverse(of c: Changes) -> Changes {
        var inv = Changes()
        Self.invert(entries, c.upsertEntries, c.deleteEntries, &inv.upsertEntries, &inv.deleteEntries)
        Self.invert(groups, c.upsertGroups, c.deleteGroups, &inv.upsertGroups, &inv.deleteGroups)
        Self.invert(absences, c.upsertAbsences, c.deleteAbsences, &inv.upsertAbsences, &inv.deleteAbsences)
        Self.invert(projects, c.upsertProjects, c.deleteProjects, &inv.upsertProjects, &inv.deleteProjects)
        Self.invert(rules, c.upsertRules, c.deleteRules, &inv.upsertRules, &inv.deleteRules)
        // Rules displaced by a key move come back too.
        for r in c.upsertRules {
            inv.upsertRules += rules.filter { $0.type == r.type && $0.instanceId == r.instanceId && $0.value == r.value && $0.id != r.id }
        }
        Self.invert(customDays, c.upsertCustomDays, c.deleteCustomDays, &inv.upsertCustomDays, &inv.deleteCustomDays)
        Self.invert(schedule, c.upsertSchedule, c.deleteSchedule, &inv.upsertSchedule, &inv.deleteSchedule)
        return inv
    }

    static func invert<T: Identifiable>(_ current: [T], _ upsert: [T], _ delete: [T.ID], _ invUpsert: inout [T], _ invDelete: inout [T.ID]) where T.ID: Hashable {
        let byId = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for x in upsert {
            if let old = byId[x.id] { invUpsert.append(old) } else { invDelete.append(x.id) }
        }
        for id in delete {
            if let old = byId[id] { invUpsert.append(old) }
        }
    }
}
