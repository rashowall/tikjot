import Foundation

/// "Needs you" — one definition for every screen (audit U1): only what blocks sending. A worklog that is simply
/// not in Jira yet never needs you; it is "Not in Jira" (a calm amount).
///
/// Blockers: a finished entry without a task, a worklog that failed, changed in Jira and here (conflict), was
/// deleted in Jira, or whose task can't be used any more — and a workday that is over with nothing tracked.
public struct NeedsYou: Equatable, Sendable {
    /// Finished entries without a task.
    public var noTask = 0
    /// Worklogs that failed / conflict / were deleted in Jira / lost their task.
    public var worklogs = 0
    /// Workdays that are over with nothing tracked.
    public var emptyDays: [LocalDate] = []
    /// Every day with at least one blocker (sorted).
    public var days: [LocalDate] = []

    public init() {}

    /// Entries and worklogs (no empty days).
    public var items: Int { noTask + worklogs }
    /// Everything that needs you, empty days included (the sidebar badge, Unsent's "Needs you" filter).
    public var count: Int { items + emptyDays.count }
    public var isEmpty: Bool { count == 0 }

    static func + (a: NeedsYou, b: NeedsYou) -> NeedsYou {
        var x = a
        x.noTask += b.noTask
        x.worklogs += b.worklogs
        x.emptyDays += b.emptyDays
        x.days += b.days
        return x
    }
}

/// The part of a worklog that can go to Jira now (the running entry waits until it stops, §9.8).
public struct SendablePart: Equatable, Sendable {
    /// Finished time as it will be sent (rounded like the whole worklog).
    public let value: Seconds
    /// Raw finished time.
    public let raw: Seconds
    /// The running entry is part of this worklog and is left out.
    public let excludesRunning: Bool
}

extension Ledger {
    /// What needs you on one day. `unavailable`: tasks Jira no longer accepts (deleted, no permission).
    public func needsYou(on d: LocalDate, lock: LockPolicy, jiraConnected: Bool, unavailable: Set<IssueRef> = []) -> NeedsYou {
        var n = NeedsYou()
        guard jiraConnected, d <= today, lock.canSend(d, today: today) else { return n }
        if dayStatus(d, lock: lock, jiraConnected: jiraConnected) == .missed {
            n.emptyDays = [d]
            n.days = [d]
            return n
        }
        let ls = lines(on: d)
        var seen = Set<UUID>()
        for line in ls {
            if line.isNoIssue {
                if line.entries.contains(where: { !$0.isRunning }) { n.noTask += 1 }
                continue
            }
            if let g = line.group { seen.insert(g.id) }
            let s = state(of: line, lock: lock)
            if [.error, .conflict, .remoteDeleted].contains(s) {
                n.worklogs += 1
            } else if let ref = line.issue, unavailable.contains(ref), s != .synced {
                n.worklogs += 1
            }
        }
        for g in groups(on: d) where !seen.contains(g.id) && [.error, .conflict, .remoteDeleted].contains(g.syncState) {
            n.worklogs += 1
        }
        if n.items > 0 { n.days = [d] }
        return n
    }

    /// What needs you in a range (only days up to today that can still be sent).
    public func needsYou(in range: DateRange, lock: LockPolicy, jiraConnected: Bool, unavailable: Set<IssueRef> = []) -> NeedsYou {
        let last = min(range.end, today)
        guard jiraConnected, last >= range.start else { return NeedsYou() }
        return DateRange(range.start, last).reduce(NeedsYou()) { $0 + needsYou(on: $1, lock: lock, jiraConnected: jiraConnected, unavailable: unavailable) }
    }

    /// The finished part of a worklog — what "Review & send" sends now. `nil` when nothing is finished yet.
    public func sendablePart(of line: WorklogLine) -> SendablePart? {
        guard line.containsRunning else { return SendablePart(value: line.value, raw: line.raw, excludesRunning: false) }
        let finished = line.entries.filter { !$0.isRunning }
        guard !finished.isEmpty else { return nil }
        let raw = finished.reduce(0) { $0 + $1.duration(now: now) }
        let value: Seconds
        if let g = line.group, g.sentRaw == raw, let sent = g.lastSent {
            value = sent.durationSeconds
        } else if case .imported = line.key {
            value = raw
        } else {
            value = rounding.apply(raw)
        }
        return SendablePart(value: value, raw: raw, excludesRunning: true)
    }

    /// Worklogs that aren't in Jira yet (unsent, changed, to delete) — the calm "Not in Jira" amount; blockers and
    /// entries without a task are not counted here.
    public func notInJira(in range: DateRange, lock: LockPolicy) -> (worklogs: Int, seconds: Seconds) {
        let last = min(range.end, today)
        guard last >= range.start else { return (0, 0) }
        var n = 0, s: Seconds = 0
        for d in DateRange(range.start, last) {
            for line in lines(on: d) where !line.isNoIssue {
                let st = state(of: line, lock: lock)
                if st == .unsent || st == .modified { n += 1; s += line.value }
            }
            n += groups(on: d).filter { $0.syncState == .pendingDelete }.count
        }
        return (n, s)
    }
}

/// The Unsent badge (sidebar, popover footer, menu-bar icon) — variant B of the board "Unsent badge · options"
/// (decided 2026-10-06): the number is always the days not in Jira yet, a calm grey count that turns into a solid
/// amber pill when something needs you (blocks sending). Hidden at 0 days.
public struct UnsentBadge: Equatable, Sendable {
    /// Days not in Jira yet (sorted).
    public var days: [LocalDate] = []
    /// Something blocks sending (the one "needs you" rule, audit U1).
    public var needsYou = false

    public init(days: [LocalDate] = [], needsYou: Bool = false) {
        self.days = days
        self.needsYou = needsYou
    }

    public var count: Int { days.count }
    public var isHidden: Bool { days.isEmpty }
}

extension Ledger {
    /// Whether a day has time that isn't in Jira yet — sendable or blocked. A running entry alone doesn't count;
    /// the finished part of a worklog that is still running does when Jira doesn't have it yet.
    public func hasTimeNotInJira(on d: LocalDate, lock: LockPolicy) -> Bool {
        guard lock.canSend(d, today: today) else { return false }
        for line in lines(on: d) {
            if line.isNoIssue {
                if line.entries.contains(where: { !$0.isRunning }) { return true }
                continue
            }
            if line.containsRunning {
                guard let part = sendablePart(of: line) else { continue }
                if let g = line.group, g.syncState == .synced, g.lastSent?.durationSeconds == part.value { continue }
                return true
            }
            if state(of: line, lock: lock) != .synced { return true }
        }
        return groups(on: d).contains { [.pendingDelete, .remoteDeleted, .error, .conflict].contains($0.syncState) }
    }

    /// The Unsent badge for a range (days up to today that can still be sent): days with time not in Jira, plus any
    /// day that needs you (an empty workday too, so the amber badge never says 0).
    public func unsentBadge(in range: DateRange, lock: LockPolicy, jiraConnected: Bool, unavailable: Set<IssueRef> = []) -> UnsentBadge {
        let last = min(range.end, today)
        guard jiraConnected, last >= range.start else { return UnsentBadge() }
        var b = UnsentBadge()
        for d in DateRange(range.start, last) {
            let blocked = !needsYou(on: d, lock: lock, jiraConnected: jiraConnected, unavailable: unavailable).isEmpty
            if blocked { b.needsYou = true }
            if blocked || hasTimeNotInJira(on: d, lock: lock) { b.days.append(d) }
        }
        return b
    }
}
