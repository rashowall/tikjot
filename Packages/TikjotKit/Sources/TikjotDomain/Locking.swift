import Foundation

/// §8.6 — editable window = current month + grace days into the previous month.
public struct LockPolicy: Sendable, Hashable {
    public var graceDays: Int
    public init(graceDays: Int = 5) { self.graceDays = graceDays }

    public func isLocked(_ d: LocalDate, today: LocalDate) -> Bool {
        let thisMonth = today.firstOfMonth
        if d >= thisMonth { return false }
        let prevMonth = thisMonth.adding(months: -1)
        if d >= prevMonth && today.day <= graceDays { return false }
        return true
    }

    /// Last day the given (past) month can still be edited, e.g. "editable until 5 Oct".
    public func editableUntil(_ d: LocalDate) -> LocalDate {
        let nextMonth = d.firstOfMonth.adding(months: 1)
        return nextMonth.adding(days: graceDays - 1)
    }

    public func canEditEntries(on d: LocalDate, today: LocalDate) -> Bool {
        !isLocked(d, today: today) && d <= today
    }

    /// Absences may be planned ahead.
    public func canEditAbsences(on d: LocalDate, today: LocalDate) -> Bool {
        !isLocked(d, today: today)
    }

    public func canSend(_ d: LocalDate, today: LocalDate) -> Bool {
        !isLocked(d, today: today) && d <= today
    }
}

/// Per-day summary status (§9.6 "Day and month views aggregate these").
public enum DayStatus: String, Sendable, Hashable {
    /// Nothing to show (day off without work, future).
    case none
    /// Everything in Jira.
    case allInJira
    /// Waiting to be sent (new or changed).
    case waiting
    case failed
    case conflict
    /// Workday that is over with nothing tracked.
    case missed
    case locked

    /// Only these get the amber "needs you" dot (§7.3 date picker).
    public var needsYou: Bool {
        switch self {
        case .waiting, .failed, .conflict, .missed: return true
        default: return false
        }
    }
}

extension Ledger {
    /// Sync state of a line (§9.6) — groups are the source of truth, entries without an issue are `noIssue`.
    public func state(of line: WorklogLine, lock: LockPolicy) -> SyncState {
        if lock.isLocked(line.date, today: today) { return .locked }
        if line.isNoIssue { return .noIssue }
        guard let g = line.group else { return .unsent }
        switch g.syncState {
        case .synced:
            // Recompute: did anything change since it was sent?
            if g.lastSent != nil && !matchesSent(line) { return .modified }
            return .synced
        default:
            return g.syncState
        }
    }

    /// Jira already has exactly this line: same time, start (within a minute) and comment (normalised).
    public func matchesSent(_ line: WorklogLine) -> Bool {
        guard let sent = line.group?.lastSent else { return false }
        return sent.durationSeconds == line.value && JiraComment.normalized(sent.comment) == JiraComment.normalized(line.comment)
            && abs(sent.startedAt.timeIntervalSince(line.started)) < 60
    }

    /// Failed updates with nothing left to send (beta 2026-10-25, a tester): the worklog is in Jira and the line now
    /// matches it — e.g. an "Update" that was only the old list form, refused because the task is closed. They go
    /// back to In Jira instead of waiting in Unsent for ever. Open days only; a create that failed never matches.
    public func failedButInJira(lock: LockPolicy) -> [WorklogGroup] {
        let days = Set(groups.values.filter { $0.syncState == .error && $0.remoteWorklogId != nil && $0.deletedAt == nil }.map(\.localDate))
        return days.flatMap { lines(on: $0) }.compactMap { line in
            guard var g = line.group, g.syncState == .error, g.remoteWorklogId != nil, !line.containsRunning,
                  !lock.isLocked(line.date, today: today), matchesSent(line) else { return nil }
            g.syncState = .synced
            g.lastError = nil
            return g
        }
    }

    public func dayStatus(_ d: LocalDate, lock: LockPolicy, jiraConnected: Bool = true) -> DayStatus {
        if d > today { return .none }
        let ls = lines(on: d)
        if lock.isLocked(d, today: today) { return ls.isEmpty ? .none : .locked }
        let groupsOnly = groups(on: d).filter { g in g.syncState == .pendingDelete || g.syncState == .remoteDeleted }
        if ls.isEmpty && groupsOnly.isEmpty {
            if let k = knownFrom, d < k { return .none }
            let over = d < today || now >= d.at(minutes: calendar.schedule.period(on: d).workdayEnd, in: timeCalendar)
            return calendar.fund(d) > 0 && over ? .missed : .none
        }
        guard jiraConnected else { return .none }
        let states = ls.filter { !$0.containsRunning }.map { state(of: $0, lock: lock) } + groupsOnly.map(\.syncState)
        if states.contains(.conflict) { return .conflict }
        if states.contains(.error) { return .failed }
        if states.contains(where: { [.unsent, .modified, .pendingDelete, .remoteDeleted, .noIssue].contains($0) }) {
            return .waiting
        }
        return states.isEmpty ? .none : .allInJira
    }
}

/// Comment normalisation used to compare what was sent with what would be sent now. Jira gives back what it
/// stored, not what we sent: Data Center reads lines of "- " / "* " as a list ("• "), Cloud trims each paragraph
/// and drops empty ones, line ends may come back as \r\n. Beta 2026-10-22 (a tester): a multi-line description stayed
/// "Update" forever after sending. Both sides go through this, so only a real change in the text counts.
/// Beta 2026-10-25 (a tester): worklogs sent before one-point-per-line (#126) still read "Update" — several
/// descriptions went as "• - a\n- b\n• c" (the typed marks inside our bullets). With two or more lines only the
/// points count now: every line, its list marks stripped (also nested ones), the same point once — so the list's
/// form never makes a worklog look changed, a changed word still does.
public enum JiraComment {
    static let marks = ["• ", "* ", "- "]

    public static func normalized(_ s: String) -> String {
        let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2 else { return lines.joined(separator: "\n") }
        var seen = Set<String>()
        var points: [String] = []
        for l in lines {
            let p = unmarked(l)
            if seen.insert(p.lowercased()).inserted { points.append("• " + p) }
        }
        return points.joined(separator: "\n")
    }

    /// "• - Handover" → "Handover"; a line that is only a mark stays as it is.
    static func unmarked(_ line: String) -> String {
        var l = Substring(line)
        while let m = marks.first(where: { l.hasPrefix($0) }) {
            let rest = l.dropFirst(m.count).drop(while: { $0 == " " })
            if rest.isEmpty { break }
            l = rest
        }
        return String(l)
    }
}
