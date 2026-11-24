import Foundation

/// The running timer across sleep, midnight and "I was away" answers (§7.1, §7.2, audit U3 / S-wake).
public enum AwayOps {
    /// Whether a clock reading moved to another calendar day (e.g. waking after midnight). Compare with the reading
    /// from *before* the clock is advanced — after it, both sides are already "today".
    public static func dayChanged(from old: Date, to new: Date, calendar: Calendar) -> Bool {
        LocalDate(old, calendar: calendar) != LocalDate(new, calendar: calendar)
    }

    /// A running timer that started before today, stored per day: finished parts that end at each midnight
    /// (the first keeps the entry's id), plus a new running entry from today's 00:00. Empty when nothing crossed.
    public static func splitRunning(_ r: TimeEntry, today: LocalDate, calendar: Calendar) -> [TimeEntry] {
        guard r.isRunning, LocalDate(r.start, calendar: calendar) < today else { return [] }
        var parts: [TimeEntry] = []
        var cur = r.start
        while LocalDate(cur, calendar: calendar) < today {
            let end = LocalDate(cur, calendar: calendar).end(in: calendar)
            var p = r
            p.start = cur
            p.end = end
            if cur != r.start { p.id = UUID(); p.worklogGroupId = nil }
            parts.append(p)
            cur = end
        }
        parts.append(TimeEntry(start: cur, end: nil, instanceId: r.instanceId, issueId: r.issueId, projectId: r.projectId,
                               description: r.description))
        return parts
    }

    /// The running timer and the parts it was split into at midnight (same task, back to back), oldest first.
    public static func runningChain(_ r: TimeEntry, entries: [TimeEntry]) -> [TimeEntry] {
        var chain = [r]
        var cur = r
        while let prev = entries.first(where: { $0.id != cur.id && $0.deletedAt == nil && $0.end == cur.start && sameTask($0, cur) }) {
            chain.insert(prev, at: 0)
            cur = prev
        }
        return chain
    }

    /// "Stop at <time you left>": the timer ends at `from` and doesn't restart. Parts that started after `from`
    /// (midnight splits while the Mac slept) are removed; the part running at `from` ends there.
    public static func stop(at from: Date, running r: TimeEntry, entries: [TimeEntry]) -> EntryChange {
        var change = EntryChange()
        for e in runningChain(r, entries: entries) {
            if e.start >= from {
                change.deleted.append(e)
            } else if e.isRunning || (e.end ?? from) > from {
                var x = e
                x.end = from
                change.updated.append(x)
            }
        }
        return change
    }

    static func sameTask(_ a: TimeEntry, _ b: TimeEntry) -> Bool {
        a.instanceId == b.instanceId && a.issueId == b.issueId && a.projectId == b.projectId && a.description == b.description && a.kind == b.kind
    }
}
