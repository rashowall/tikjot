import Foundation

/// A period's worked and expected hours as far as it has gone (owner 2026-10-07: "Trend by week doesn't take into
/// account where we are in the current week"). A running period (it contains today) is compared with what was
/// expected *to date*, by the balance's own rule (`Ledger.dayBalance`): past days whole, later days nothing, today its
/// fund once the working day is over — before that only as much as is already worked (no shortfall during the day,
/// overtime at once). So `balance == Ledger.liveBalance(range, since:)`: every "so far" number agrees with the
/// balance in the sidebar, toolbars, Month and the widget.
public struct PeriodSoFar: Equatable, Sendable {
    /// Worked through today (today: tracked so far), rounded as in Jira.
    public var worked: Seconds
    /// Expected to date (see above): the whole fund for a past period, 0 for a future one.
    public var expected: Seconds
    /// The whole period's fund.
    public var full: Seconds
    /// The period contains today: its numbers are "so far".
    public var isRunning: Bool

    public var balance: Seconds { worked - expected }
    /// The full fund is still ahead: show it beside the to-date value ("Expected so far 23h · Full week 39h").
    public var hasMoreToCome: Bool { full != expected }

    public init(worked: Seconds, expected: Seconds, full: Seconds, isRunning: Bool) {
        self.worked = worked; self.expected = expected; self.full = full; self.isRunning = isRunning
    }
}

extension Ledger {
    /// A day's expected hours so far: past days their fund, later days 0, today its fund once it counts in the
    /// balance (worked it, or the working day is over), else what is worked — `worked(d) − expectedSoFar(d) == dayBalance(d)`.
    public func expectedSoFar(_ d: LocalDate) -> Seconds {
        if d < today { return fund(d) }
        if d > today { return 0 }
        return worked(d) - dayBalance(d)
    }

    /// Expected hours of `range` to date (`since`: days before it don't count, as in `liveBalance`).
    public func expectedSoFar(_ range: DateRange, since: LocalDate? = nil) -> Seconds {
        soFar(range, since: since).expected
    }

    /// `range` as far as it has gone; `since`: the first day tikjot knows — earlier days count neither worked nor
    /// expected (as in `liveBalance`).
    public func soFar(_ range: DateRange, since: LocalDate? = nil) -> PeriodSoFar {
        let t = today
        let running = range.contains(t)
        let first = max(range.start, since ?? range.start)
        guard first <= range.end else { return PeriodSoFar(worked: 0, expected: 0, full: 0, isRunning: running) }
        let counted = DateRange(first, range.end)
        let last = min(counted.end, t)
        var worked = 0, expected = 0
        if last >= counted.start {
            let past = DateRange(counted.start, last)
            worked = self.worked(past)
            expected = past.reduce(0) { $0 + expectedSoFar($1) }
        }
        return PeriodSoFar(worked: worked, expected: expected, full: fund(counted), isRunning: running)
    }
}
