import Foundation
import TikjotDomain
import TikjotPersistence

/// After a Data Center → Cloud link (§9.11), projects follow their Jira keys across (beta 2026-11-16, testers):
/// - The new site was imported before the link, so its keys got their own projects ("Internal activities" twice,
///   one colour each). Such a project — still named as tikjot named it — merges into the old one.
/// - Cloud keys have no underscore: OPS_DESK became OPSDESK. The renamed key joins the old project when the new
///   site really has it under the same Jira project name.
/// - Work never sent whose task the new site has (same key, or the renamed key with the same summary) moves there:
///   an archived site sends nothing.
/// Pure and idempotent: it runs on every reconcile and does nothing once all is in place.
public enum SuccessionHeal {
    /// "OPS_DESK" → "OPSDESK"; nil when the key has no underscore.
    public static func cloudKey(_ projectKey: String) -> String? {
        projectKey.contains("_") ? projectKey.replacingOccurrences(of: "_", with: "") : nil
    }

    /// "OPS_DESK-12" → "OPSDESK-12".
    public static func cloudIssueKey(_ key: String) -> String? {
        guard let dash = key.lastIndex(of: "-"), let p = cloudKey(String(key[..<dash])) else { return nil }
        return p + key[dash...]
    }

    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        func n(_ s: String) -> String {
            s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }
        let x = n(a)
        return !x.isEmpty && x == n(b)
    }

    public static func changes(_ data: DataSnapshot) -> Changes {
        var c = Changes()
        let pairs = data.instances.compactMap { s -> (UUID, UUID)? in
            guard s.deletedAt == nil, let p = s.successorOf,
                  data.instances.contains(where: { $0.id == p && $0.status == .archived }) else { return nil }
            return (s.id, p)
        }
        guard !pairs.isEmpty else { return c }
        var d = data
        for (succ, pred) in pairs {
            let step = changes(succ: succ, pred: pred, d)
            guard !step.isEmpty else { continue }
            d.apply(step)
            c.upsertRules += step.upsertRules
            c.deleteRules += step.deleteRules
            c.upsertEntries += step.upsertEntries
            c.deleteProjects += step.deleteProjects
        }
        return c
    }

    private static func changes(succ: UUID, pred: UUID, _ data: DataSnapshot) -> Changes {
        var c = Changes()
        var projects = Dictionary(data.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rules = data.rules
        let oldIssues = data.issues.filter { $0.instanceId == pred }
        let newIssues = data.issues.filter { $0.instanceId == succ }
        var oldNames: [String: String] = [:]
        for i in oldIssues { if let n = i.projectName, !n.isEmpty { oldNames[i.projectKey] = n } }
        var newNames: [String: String] = [:]
        for i in newIssues { newNames[i.projectKey] = newNames[i.projectKey] ?? i.projectName ?? "" }

        // 1. Projects follow the keys.
        var entryProject: [UUID: UUID] = [:]   // merged project → the one it went into
        for r in rules.filter({ $0.instanceId == pred }).sorted(by: { $0.value < $1.value }) {
            guard let target = projects[r.projectId] else { continue }
            var candidates = [(r.value, true)]
            if let k = cloudKey(r.value) { candidates.append((k, false)) }
            for (key, exact) in candidates {
                let owner = rules.first { $0.instanceId == succ && $0.value == key }
                if let owner {
                    guard owner.projectId != target.id, let q = projects[owner.projectId] else { continue }
                    // Only a project tikjot made for the new site: no old-site keys, still named as it was made.
                    guard !rules.contains(where: { $0.projectId == q.id && $0.instanceId != succ }) else { continue }
                    let autoNamed = same(q.name, target.name) || same(q.name, newNames[key]) || same(q.name, key)
                    guard autoNamed, exact || same(newNames[key], oldNames[r.value]) || same(q.name, target.name) else { continue }
                    for i in rules.indices where rules[i].projectId == q.id {
                        rules[i].projectId = target.id
                        c.upsertRules.append(rules[i])
                    }
                    projects[q.id] = nil
                    c.deleteProjects.append(q.id)
                    entryProject[q.id] = target.id
                } else if !exact, newNames[key] != nil, same(newNames[key], oldNames[r.value]) || same(newNames[key], target.name) {
                    let rule = ProjectRule(projectId: target.id, instanceId: succ, value: key)
                    rules.append(rule)
                    c.upsertRules.append(rule)
                }
            }
        }

        // The link copied the old key to the new site; where the new site has it only renamed, that copy is dead.
        for r in rules.filter({ $0.instanceId == pred }) {
            guard let ck = cloudKey(r.value), newNames[r.value] == nil,
                  rules.contains(where: { $0.instanceId == succ && $0.value == ck && $0.projectId == r.projectId }),
                  let dead = rules.first(where: { $0.instanceId == succ && $0.value == r.value && $0.projectId == r.projectId }) else { continue }
            rules.removeAll { $0.id == dead.id }
            c.deleteRules.append(dead.id)
        }

        // 2. Never-sent work on the archived site whose task the new site has moves there.
        let oldById = Dictionary(oldIssues.map { ($0.issueId, $0) }, uniquingKeysWith: { a, _ in a })
        let newByKey = Dictionary(newIssues.map { ($0.key.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var moved: [UUID: TimeEntry] = [:]
        for var e in SyncEngine.neverSent(on: pred, data) {
            guard let old = e.issueId.flatMap({ oldById[$0] }) else { continue }
            let exact = newByKey[old.key.uppercased()]
            let renamed = cloudIssueKey(old.key).flatMap { newByKey[$0.uppercased()] }.flatMap { same($0.summary, old.summary) ? $0 : nil }
            guard let task = exact ?? renamed else { continue }
            e.instanceId = succ
            e.issueId = task.issueId
            moved[e.id] = e
        }

        // 3. Entries of merged projects, and new-site entries a new rule now covers, take the project.
        let succRules = Dictionary(rules.filter { $0.instanceId == succ }.map { ($0.value, $0.projectId) }, uniquingKeysWith: { a, _ in a })
        let newById = Dictionary(newIssues.map { ($0.issueId, $0) }, uniquingKeysWith: { a, _ in a })
        let touched = !c.upsertRules.isEmpty || !moved.isEmpty  // a removed dead copy covered no task
        if touched {
            for orig in data.entries where orig.deletedAt == nil {
                var e = moved[orig.id] ?? orig
                if let p = e.projectId, let into = entryProject[p] { e.projectId = into }
                if e.instanceId == succ, let i = e.issueId.flatMap({ newById[$0] }), let p = succRules[i.projectKey], e.projectId == nil || moved[e.id] != nil {
                    e.projectId = p
                }
                if e != orig { c.upsertEntries.append(e) }
            }
        }
        return c
    }
}
