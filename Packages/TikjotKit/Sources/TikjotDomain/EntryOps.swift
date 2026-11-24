import Foundation

/// A set of entry changes produced by an editing operation; applied by the store in one undoable step.
public struct EntryChange: Sendable, Equatable {
    public var inserted: [TimeEntry] = []
    public var updated: [TimeEntry] = []
    public var deleted: [TimeEntry] = []

    public init(inserted: [TimeEntry] = [], updated: [TimeEntry] = [], deleted: [TimeEntry] = []) {
        self.inserted = inserted; self.updated = updated; self.deleted = deleted
    }

    public var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && deleted.isEmpty }

    public mutating func merge(_ other: EntryChange) {
        inserted += other.inserted; updated += other.updated; deleted += other.deleted
    }
}

public struct Overlap: Hashable, Sendable {
    public let a: UUID
    public let b: UUID
    public let start: Date
    public let end: Date
    public var seconds: Seconds { Int(end.timeIntervalSince(start)) }
}

public struct Gap: Hashable, Sendable {
    public let start: Date
    public let end: Date
    public var seconds: Seconds { Int(end.timeIntervalSince(start)) }
}

public enum EntryOpError: Error, Equatable, Sendable {
    case outsideEntry
    case differentTasks
    case notAdjacent
    case nothingToMerge
    case running
    case inFuture
    case locked
}

/// Pure editing rules (§7.1, §7.3, §7.4).
public enum EntryOps {
    public static let snapMinutes = 5
    public static let minimumDuration: Seconds = 60

    // MARK: Midnight

    /// An entry never crosses local midnight (§6.5). Running entries are split for display;
    /// the last part keeps `end == nil`.
    public static func splitAtMidnight(_ e: TimeEntry, now: Date, calendar: Calendar) -> [TimeEntry] {
        let end = e.effectiveEnd(now: now)
        var parts: [TimeEntry] = []
        var cur = e.start
        while true {
            let dayEnd = LocalDate(cur, calendar: calendar).end(in: calendar)
            if end <= dayEnd {
                var p = e
                p.start = cur
                p.end = e.end == nil ? nil : end
                parts.append(p)
                break
            }
            var p = e
            p.start = cur
            p.end = dayEnd
            parts.append(p)
            cur = dayEnd
        }
        return parts
    }

    /// Splits a stored entry into per-day entries (new ids for continuation parts).
    public static func normalizeMidnight(_ e: TimeEntry, calendar: Calendar) -> EntryChange {
        guard let end = e.end else { return EntryChange() }
        let dayEnd = LocalDate(e.start, calendar: calendar).end(in: calendar)
        guard end > dayEnd else { return EntryChange() }
        var first = e
        first.end = dayEnd
        var change = EntryChange(updated: [first])
        var cur = dayEnd
        while cur < end {
            let next = min(end, LocalDate(cur, calendar: calendar).end(in: calendar))
            var p = e
            p.id = UUID()
            p.start = cur
            p.end = next
            p.worklogGroupId = nil
            p.createdAt = Date()
            change.inserted.append(p)
            cur = next
        }
        return change
    }

    // MARK: Overlaps & gaps

    public static func overlaps(_ entries: [TimeEntry], now: Date) -> [Overlap] {
        let es = entries.filter { $0.kind == .work }.sorted { $0.start < $1.start }
        var out: [Overlap] = []
        for i in es.indices {
            for j in es.indices where j > i {
                let a = es[i], b = es[j]
                let s = max(a.start, b.start)
                let e = min(a.effectiveEnd(now: now), b.effectiveEnd(now: now))
                if e > s { out.append(Overlap(a: a.id, b: b.id, start: s, end: e)) }
                if b.start >= a.effectiveEnd(now: now) { break }
            }
        }
        return out
    }

    /// Free time between entries on a day, limited to [from, to].
    public static func gaps(_ entries: [TimeEntry], from: Date, to: Date, now: Date, minimum: Seconds = 60) -> [Gap] {
        var cursor = from
        var out: [Gap] = []
        for e in entries.sorted(by: { $0.start < $1.start }) {
            let s = max(e.start, from)
            if s > cursor, Int(s.timeIntervalSince(cursor)) >= minimum { out.append(Gap(start: cursor, end: min(s, to))) }
            cursor = max(cursor, e.effectiveEnd(now: now))
            if cursor >= to { break }
        }
        if to > cursor, Int(to.timeIntervalSince(cursor)) >= minimum { out.append(Gap(start: cursor, end: to)) }
        return out.filter { $0.end > $0.start }
    }

    // MARK: Snapping

    /// Rounds to the nearest `minutes` on the wall clock (seconds ≥ 30 count as the next minute). Done on the local
    /// clock reading itself, not as an offset from midnight — on a daylight-saving day that offset is an hour off.
    public static func snap(_ date: Date, minutes: Int = snapMinutes, calendar: Calendar) -> Date {
        let offset = TimeInterval(calendar.timeZone.secondsFromGMT(for: date))
        let local = date.timeIntervalSince1970 + offset
        guard local.isFinite, abs(local) < 1e13 else { return date }
        let wholeMinutes = (local / 60).rounded(.down)
        let total = wholeMinutes + (local - wholeMinutes * 60 >= 30 ? 1 : 0)
        let snapped = (total / Double(minutes)).rounded() * Double(minutes)
        return Date(timeIntervalSince1970: snapped * 60 - offset)
    }

    /// Snap to 5 min, but stick to a neighbour's edge when within `magnet` (§7.3 "magnet").
    public static func snap(_ date: Date, toEdges edges: [Date], magnet: TimeInterval = 4 * 60, calendar: Calendar) -> Date {
        if let nearest = edges.min(by: { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }),
           abs(nearest.timeIntervalSince(date)) <= magnet {
            return nearest
        }
        return snap(date, calendar: calendar)
    }

    /// Magnet for a resized edge: 2 min (beta 2026-10-08 — 4 min grabbed the edges of short entries too eagerly).
    /// Moving a whole block keeps the 4-min default of `snap(_:toEdges:)`.
    public static let resizeMagnet: TimeInterval = 2 * 60

    /// Where a dragged edge lands: it stays on its original time until the drag passes `deadZone`, then snaps to
    /// 5 min (`fine` = 1 min, no magnet) and sticks to a neighbour's edge within `magnet`. With a dead zone of at
    /// least half a step (and a magnet no wider) the edge never lands on the other side of `original` than the pointer went.
    public static func dragEdge(_ original: Date, by delta: TimeInterval, deadZone: TimeInterval, fine: Bool = false,
                                edges: [Date], magnet: TimeInterval = resizeMagnet, calendar: Calendar) -> Date {
        guard abs(delta) >= deadZone, delta.isFinite else { return original }
        let raw = original.addingTimeInterval(delta)
        return fine ? snap(raw, minutes: 1, calendar: calendar) : snap(raw, toEdges: edges, magnet: magnet, calendar: calendar)
    }

    // MARK: Timer (§7.1)

    /// Start a timer: stops the running one at the same instant (contiguous).
    public static func start(_ new: TimeEntry, running: TimeEntry?, at instant: Date) -> EntryChange {
        var change = EntryChange()
        if var r = running {
            if instant.timeIntervalSince(r.start) < Double(minimumDuration) {
                change.deleted.append(r)
            } else {
                r.end = max(r.start, instant)
                r.updatedAt = Date()
                change.updated.append(r)
            }
        }
        var n = new
        n.end = nil
        change.inserted.append(n)
        return change
    }

    /// Stop the running entry; shorter than a minute → discarded (undoable).
    public static func stop(_ running: TimeEntry, at instant: Date) -> (change: EntryChange, discarded: Bool) {
        if instant.timeIntervalSince(running.start) < Double(minimumDuration) {
            return (EntryChange(deleted: [running]), true)
        }
        var r = running
        r.end = instant
        r.updatedAt = Date()
        return (EntryChange(updated: [r]), false)
    }

    /// Continue: new entry with the same issue, project and description (§7.1).
    public static func continuation(of e: TimeEntry, at instant: Date) -> TimeEntry {
        TimeEntry(start: instant, end: nil, instanceId: e.instanceId, issueId: e.issueId, projectId: e.projectId,
                  description: e.description, source: .local)
    }

    // MARK: Day editing (§7.3)

    public static func split(_ e: TimeEntry, at t: Date) throws -> EntryChange {
        guard let end = e.end, t > e.start, t < end else { throw EntryOpError.outsideEntry }
        var first = e
        first.end = t
        first.updatedAt = Date()
        var second = e
        second.id = UUID()
        second.start = t
        second.worklogGroupId = e.source == .imported ? nil : e.worklogGroupId
        second.source = .local
        second.createdAt = Date()
        return EntryChange(inserted: [second], updated: [first])
    }

    /// Take out a range; optionally give it to another task (`replacement` gets the carved range).
    public static func carve(_ e: TimeEntry, from: Date, to: Date, replacement: TimeEntry? = nil) throws -> EntryChange {
        guard let end = e.end else { throw EntryOpError.outsideEntry }
        let s = max(from, e.start), t = min(to, end)
        guard t > s else { throw EntryOpError.outsideEntry }
        var change = EntryChange()
        if s <= e.start && t >= end {
            change.deleted.append(e)
        } else if s <= e.start {
            var x = e; x.start = t; x.updatedAt = Date(); change.updated.append(x)
        } else if t >= end {
            var x = e; x.end = s; x.updatedAt = Date(); change.updated.append(x)
        } else {
            var a = e; a.end = s; a.updatedAt = Date()
            var b = e; b.id = UUID(); b.start = t; b.source = .local; b.createdAt = Date()
            if e.source == .imported { b.worklogGroupId = nil }
            change.updated.append(a); change.inserted.append(b)
        }
        if var r = replacement {
            r.start = s; r.end = t
            change.inserted.append(r)
        }
        return change
    }

    /// Why `entries` can't be merged, nil when they can: two or more, none running, one task, and — given the
    /// day's entries — nothing else in between (§7.3 "merge adjacent"; beta 2026-10-22: two same-task entries
    /// with another task between them merged over it).
    public static func mergeProblem(_ entries: [TimeEntry], within day: [TimeEntry] = []) -> EntryOpError? {
        guard entries.count >= 2 else { return .nothingToMerge }
        guard entries.allSatisfy({ $0.end != nil }) else { return .running }
        let first = entries[0]
        guard entries.allSatisfy({ sameTask($0, first) }) else { return .differentTasks }
        let ids = Set(entries.map(\.id))
        let start = entries.map(\.start).min()!, end = entries.compactMap(\.end).max()!
        if day.contains(where: { !ids.contains($0.id) && $0.start < end && ($0.end ?? .distantFuture) > start }) { return .notAdjacent }
        return nil
    }

    /// Time a merge adds: the empty minutes between the entries, which the merged block covers (§7.3). The merge
    /// toast names it, so a merge over lunch never adds an hour unseen (owner 2026-10-22).
    public static func mergeGap(_ entries: [TimeEntry]) -> Seconds {
        var gap: Seconds = 0
        var reached: Date?
        for e in entries.sorted(by: { $0.start < $1.start }) {
            guard let end = e.end else { continue }
            if let r = reached, e.start > r { gap += Int(e.start.timeIntervalSince(r)) }
            reached = max(reached ?? end, end)
        }
        return gap
    }

    public static func sameTask(_ a: TimeEntry, _ b: TimeEntry) -> Bool {
        a.instanceId == b.instanceId && a.issueId == b.issueId && a.projectId == b.projectId
    }

    /// Merge entries of the same task into the first; descriptions joined with "; ", gaps included.
    /// `day`: the day's entries, for the nothing-in-between check.
    public static func merge(_ entries: [TimeEntry], within day: [TimeEntry] = []) throws -> EntryChange {
        let es = entries.sorted { $0.start < $1.start }
        if let problem = mergeProblem(es, within: day) { throw problem }
        let first = es[0]
        var merged = first
        merged.end = es.compactMap(\.end).max()
        merged.description = WorklogLine.uniqueDescriptions(es).joined(separator: "; ")
        merged.updatedAt = Date()
        return EntryChange(updated: [merged], deleted: Array(es.dropFirst()))
    }

    /// Overlap fix: end `e` where `other` starts.
    public static func trim(_ e: TimeEntry, before other: TimeEntry) -> EntryChange {
        var x = e
        if other.start > e.start {
            x.end = other.start
        } else if let oe = other.end {
            x.start = oe
        }
        x.updatedAt = Date()
        return EntryChange(updated: [x])
    }

    /// Overlap fix: move `e` to start right after `other` (keeps its length).
    public static func move(_ e: TimeEntry, after other: TimeEntry, now: Date) -> EntryChange {
        let len = e.effectiveEnd(now: now).timeIntervalSince(e.start)
        var x = e
        x.start = other.effectiveEnd(now: now)
        if e.end != nil { x.end = x.start.addingTimeInterval(len) }
        x.updatedAt = Date()
        return EntryChange(updated: [x])
    }

    /// Where "Add entry / N" puts a new entry (§7.3, decided 2026-10-02):
    /// the latest free time of the day (today: until now), else right after the last entry (30 min),
    /// else at `workdayStart`.
    public static func placementForNewEntry(on day: LocalDate, entries: [TimeEntry], workdayStartMinutes: Int,
                                            now: Date, calendar: Calendar, length: TimeInterval = 30 * 60) -> (Date, Date) {
        let today = LocalDate(now, calendar: calendar)
        let dayStart = day.start(in: calendar)
        let es = entries.filter { $0.kind == .work || $0.kind == .breakTime }.sorted { $0.start < $1.start }
        guard let last = es.last else {
            let s = day.at(minutes: workdayStartMinutes, in: calendar)
            if day == today && s >= now {
                let e = snap(now, calendar: calendar)
                return (e.addingTimeInterval(-length), e)
            }
            return (s, s.addingTimeInterval(length))
        }
        let from = max(dayStart, es.first!.start)
        let lastEnd = es.map { $0.effectiveEnd(now: now) }.max()!
        let to = day == today ? max(lastEnd, snap(now, calendar: calendar)) : lastEnd
        let gaps = gaps(es, from: from, to: to, now: now, minimum: 5 * 60)
        if let g = gaps.last {
            return (g.start, g.end)
        }
        let s = max(last.effectiveEnd(now: now), lastEnd)
        return (s, s.addingTimeInterval(length))
    }

    // MARK: Week grid (§7.4)

    /// Set the task's total for a day to `target`. `dayEntries` = all work entries of that day.
    public static func setCell(task: TimeEntry, dayEntries: [TimeEntry], current: Seconds, target: Seconds,
                               day: LocalDate, workdayStartMinutes: Int, description: String, now: Date,
                               calendar: Calendar) -> EntryChange {
        let mine = dayEntries.filter { $0.instanceId == task.instanceId && $0.issueId == task.issueId && $0.projectId == task.projectId }
            .sorted { $0.start < $1.start }
        if target == current { return EntryChange() }
        if target <= 0 { return EntryChange(deleted: mine) }
        if target > current {
            let add = TimeInterval(target - current)
            let lastOfDay = dayEntries.max { $0.effectiveEnd(now: now) < $1.effectiveEnd(now: now) }
            if let mineLast = mine.last, let lastOfDay, mineLast.id == lastOfDay.id, var x = mine.last, x.end != nil {
                x.end = x.end!.addingTimeInterval(add)
                x.updatedAt = Date()
                return EntryChange(updated: [x])
            }
            let start = lastOfDay?.effectiveEnd(now: now) ?? day.at(minutes: workdayStartMinutes, in: calendar)
            var n = task
            n.id = UUID()
            n.start = start
            n.end = start.addingTimeInterval(add)
            n.description = description
            n.source = .local
            n.worklogGroupId = nil
            n.createdAt = Date(); n.updatedAt = Date()
            return EntryChange(inserted: [n])
        }
        // Decrease: shorten the task's last entries from the end.
        var remove = current - target
        var change = EntryChange()
        for var e in mine.reversed() where remove > 0 {
            let d = e.duration(now: now)
            if d <= remove {
                change.deleted.append(e)
                remove -= d
            } else {
                e.end = e.effectiveEnd(now: now).addingTimeInterval(TimeInterval(-remove))
                e.updatedAt = Date()
                change.updated.append(e)
                remove = 0
            }
        }
        return change
    }
}
