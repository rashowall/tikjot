import Foundation
import TikjotDomain
import TikjotPersistence

/// Keeps worklog groups in step with entries after any local change (§6.6):
/// exactly one `app` group per (instance, issue, day); imported entries keep their own group;
/// a group whose entries are gone becomes `pendingDelete` if it exists (or may exist) in Jira.
public enum Reconciler {
    public static func reconcile(_ data: DataSnapshot, calendar: Calendar, lock: LockPolicy, today: LocalDate, now: Date = Date()) -> Changes {
        var changes = Changes()
        var groups = Dictionary(data.groups.filter { $0.deletedAt == nil }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var appByKey: [String: UUID] = [:]
        for g in groups.values where g.kind == .app {
            let k = key(g.instanceId, g.issueId, g.localDate)
            // Prefer a group that exists in Jira when duplicates exist.
            if let existing = appByKey[k], groups[existing]?.remoteWorklogId != nil { continue }
            appByKey[k] = g.id
        }
        var touched = Set<UUID>()
        var groupHasEntries = Set<UUID>()
        var updatedEntries: [TimeEntry] = []

        for var e in data.entries where e.deletedAt == nil && e.kind == .work {
            let day = LocalDate(e.start, calendar: calendar)
            guard let ref = e.issueRef else {
                if e.worklogGroupId != nil { e.worklogGroupId = nil; updatedEntries.append(e) }
                continue
            }
            if e.source == .imported, let gid = e.worklogGroupId, var g = groups[gid], g.kind == .imported,
               g.instanceId == ref.instanceId, g.issueId == ref.issueId {
                if g.localDate != day && !lock.isLocked(g.localDate, today: today) {
                    g.localDate = day
                    groups[gid] = g
                    touched.insert(gid)
                }
                groupHasEntries.insert(gid)
                continue
            }
            if e.source == .imported {
                // Imported entry moved to another task: it becomes a local entry; the old worklog will be deleted.
                e.source = .local
            }
            let k = key(ref.instanceId, ref.issueId, day)
            let gid: UUID
            if let existing = appByKey[k] {
                gid = existing
            } else {
                let g = WorklogGroup(instanceId: ref.instanceId, issueId: ref.issueId, localDate: day, kind: .app, syncState: .unsent)
                groups[g.id] = g
                appByKey[k] = g.id
                touched.insert(g.id)
                gid = g.id
            }
            groupHasEntries.insert(gid)
            if e.worklogGroupId != gid {
                e.worklogGroupId = gid
                updatedEntries.append(e)
            } else if data.entries.first(where: { $0.id == e.id })?.source != e.source {
                updatedEntries.append(e)
            }
        }

        for (id, var g) in groups {
            if lock.isLocked(g.localDate, today: today) { continue }
            if groupHasEntries.contains(id) {
                if g.syncState == .pendingDelete {
                    g.syncState = g.remoteWorklogId == nil ? .unsent : .synced
                    groups[id] = g
                    touched.insert(id)
                }
                continue
            }
            if g.remoteWorklogId != nil || g.createOutcomeUnknown {
                // A create whose answer was lost may be in Jira too: keep the group (and its marker) so the
                // delete can look for that worklog first, instead of leaving it orphaned there.
                if g.syncState == .remoteDeleted {
                    // Gone on both sides.
                    changes.deleteGroups.append(id)
                } else if g.syncState != .pendingDelete && g.syncState != .conflict {
                    g.syncState = .pendingDelete
                    groups[id] = g
                    touched.insert(id)
                }
            } else {
                changes.deleteGroups.append(id)
            }
        }
        changes.upsertGroups = touched.compactMap { groups[$0] }.filter { !changes.deleteGroups.contains($0.id) }
        changes.upsertEntries = updatedEntries
        _ = now
        return changes
    }

    static func key(_ i: UUID, _ issue: String, _ d: LocalDate) -> String { "\(i.uuidString)|\(issue)|\(d)" }
}
