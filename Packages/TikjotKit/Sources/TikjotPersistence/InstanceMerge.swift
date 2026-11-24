import Foundation
import TikjotDomain

/// Two connections to the same Jira site and account (e.g. onboarding run again) would import every
/// worklog twice. `findSame` lets connect reuse the existing one; `mergeDuplicates` repairs data that
/// already has a twin: the oldest connection stays, worklogs it already knows are dropped, the rest moves over.
public enum InstanceMerge {
    /// Scheme, host, port (default ports spelled out) and path — `https://jira.acme.com` and
    /// `https://jira.acme.com:443/` are the same site, `http://…` or another port is not.
    public static func siteKey(_ url: URL) -> String {
        let scheme = (url.scheme ?? "https").lowercased()
        let host = (url.host() ?? "").lowercased()
        let port = url.port ?? (scheme == "http" ? 80 : 443)
        var path = url.path().lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host):\(port)\(path)"
    }

    public static func findSame(in data: DataSnapshot, baseURL: URL, accountId: String) -> JiraInstance? {
        data.instances.filter { $0.accountId == accountId && siteKey($0.baseURL) == siteKey(baseURL) }
            .min { $0.createdAt < $1.createdAt }
    }

    public struct Result {
        public var changes = Changes()
        /// (removed twin, kept instance) — the app moves the Keychain token.
        public var merged: [(removed: UUID, kept: UUID)] = []
    }

    public static func mergeDuplicates(in data: DataSnapshot) -> Result {
        var r = Result()
        let twins = Dictionary(grouping: data.instances.filter { $0.accountId != nil }) { "\(siteKey($0.baseURL))|\($0.accountId!)" }
        for list in twins.values where list.count > 1 {
            let sorted = list.sorted { $0.createdAt < $1.createdAt }
            var keeper = sorted[0]
            for dup in sorted.dropFirst() {
                let knownRemote = Set(data.groups.filter { $0.instanceId == keeper.id }.compactMap(\.remoteWorklogId))
                var dropped = Set<UUID>()
                for var g in data.groups where g.instanceId == dup.id {
                    if let rid = g.remoteWorklogId, knownRemote.contains(rid) {
                        dropped.insert(g.id)
                        r.changes.deleteGroups.append(g.id)
                    } else {
                        g.instanceId = keeper.id
                        r.changes.upsertGroups.append(g)
                    }
                }
                for var e in data.entries where e.instanceId == dup.id {
                    if let gid = e.worklogGroupId, dropped.contains(gid) {
                        r.changes.deleteEntries.append(e.id)
                    } else {
                        e.instanceId = keeper.id
                        r.changes.upsertEntries.append(e)
                    }
                }
                let keeperIssues = Set(data.issues.filter { $0.instanceId == keeper.id }.map(\.issueId))
                for var i in data.issues where i.instanceId == dup.id && !keeperIssues.contains(i.issueId) {
                    i.instanceId = keeper.id
                    r.changes.upsertIssues.append(i)
                }
                let keeperRules = Set(data.rules.filter { $0.instanceId == keeper.id }.map { "\($0.type.rawValue)|\($0.value)" })
                for var x in data.rules where x.instanceId == dup.id {
                    if keeperRules.contains("\(x.type.rawValue)|\(x.value)") { r.changes.deleteRules.append(x.id) }
                    else { x.instanceId = keeper.id; r.changes.upsertRules.append(x) }
                }
                let keeperSources = Set(data.suggestionSources.filter { $0.instanceId == keeper.id }.map(\.value))
                for var s in data.suggestionSources where s.instanceId == dup.id {
                    if keeperSources.contains(s.value) { r.changes.deleteSuggestionSources.append(s.id) }
                    else { s.instanceId = keeper.id; r.changes.upsertSuggestionSources.append(s) }
                }
                // The twin was connected last, so its details (token, status) are the fresh ones.
                keeper.status = dup.status
                keeper.authMethod = dup.authMethod
                keeper.login = dup.login
                keeper.tokenExpires = dup.tokenExpires
                if let a = keeper.historyStartDate, let b = dup.historyStartDate { keeper.historyStartDate = min(a, b) }
                else { keeper.historyStartDate = keeper.historyStartDate ?? dup.historyStartDate }
                r.changes.deleteInstances.append(dup.id)
                r.merged.append((dup.id, keeper.id))
            }
            r.changes.upsertInstances.append(keeper)
        }
        return r
    }
}
