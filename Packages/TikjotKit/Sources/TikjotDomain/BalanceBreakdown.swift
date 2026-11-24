import Foundation

/// How a month's balance comes about (the tooltip on every month balance): expected = workdays × hours − absences,
/// worked (rounded, as in Jira), balance, and the running balance since its start. The numbers are the ones the UI
/// shows: `balance == Ledger.liveBalance(month, since:)`.
public struct BalanceBreakdown: Equatable, Sendable {
    public struct Deduction: Equatable, Sendable {
        public var typeId: UUID
        public var seconds: Seconds
    }

    /// The days in the sum (from the first day tikjot knows; today once it counts, see `Ledger.dayBalance`). Nil: none yet.
    public var counted: DateRange?
    /// Working days among them (workdays and company days with hours).
    public var workdays: Int
    /// The expected hours of every counted workday when they're all the same (else nil: "7 workdays 52h").
    public var perDay: Seconds?
    /// Σ expected hours before absences.
    public var base: Seconds
    /// What absences took off, per absence type, in order of appearance (capped at the day's hours).
    public var absences: [Deduction]
    /// Public holidays and company days off that fell on a working weekday.
    public var holidays: Int
    /// base − absences.
    public var expected: Seconds
    /// Rounded, as sent to Jira.
    public var worked: Seconds
    public var balance: Seconds { worked - expected }
    /// The running balance's start, when it reaches before this month or carries an opening balance; else nil.
    public var since: LocalDate?
    public var sinceBalance: Seconds
}

extension Ledger {
    /// Running balance from `start` through today (today as in `dayBalance`), with the opening balance.
    public func liveCumulativeBalance(since start: LocalDate, opening: OpeningBalance?) -> Seconds {
        cumulativeBalance(since: start, opening: opening) + (today >= start ? dayBalance(today) : 0)
    }

    /// The parts of `liveBalance(month, since:)`; `runningSince` / `opening`: the running balance (shown only for
    /// the current month).
    public func balanceBreakdown(month: DateRange, since: LocalDate, runningSince: LocalDate, opening: OpeningBalance?) -> BalanceBreakdown {
        let t = today
        let first = max(month.start, since)
        var last = min(month.end, t.adding(days: -1))
        // Today counts when its ± does (overtime at once, a shortfall after the working day) — as in `liveBalance`.
        if month.contains(t), t >= first, dayBalance(t) == worked(t) - fund(t) { last = t }
        let counted = last >= first ? DateRange(first, last) : nil

        var workdays = 0, base = 0, holidays = 0
        var perDays = Set<Seconds>()
        var absences: [BalanceBreakdown.Deduction] = []
        for d in counted.map(Array.init) ?? [] {
            let b = calendar.baseFund(d)
            base += b
            if calendar.isWorkday(d) { workdays += 1; perDays.insert(b) }
            let type = calendar.dayType(d)
            if (type == .holiday || type == .custom && b == 0), calendar.schedule.period(on: d).workdays.contains(d.isoWeekday) { holidays += 1 }
            // Same amounts as `DayCalendar.absenceSeconds`, capped so that base − absences = fund.
            var left = b
            for a in calendar.absences[d] ?? [] where left > 0 {
                let amount: Seconds
                switch a.unit {
                case .day: amount = b
                case .halfDay: amount = calendar.schedule.period(on: d).dailySeconds / 2
                case .hours: amount = a.amountSeconds
                }
                let take = min(left, max(0, amount))
                guard take > 0 else { continue }
                left -= take
                if let i = absences.firstIndex(where: { $0.typeId == a.typeId }) { absences[i].seconds += take } else { absences.append(.init(typeId: a.typeId, seconds: take)) }
            }
        }
        let expectedSum = counted.map { fund($0) } ?? 0
        let workedSum = counted.map { self.worked($0) } ?? 0

        var sinceDate: LocalDate?
        var sinceBalance = 0
        if month.contains(t) {
            sinceBalance = liveCumulativeBalance(since: runningSince, opening: opening)
            if runningSince < first || sinceBalance != workedSum - expectedSum { sinceDate = runningSince }
        }
        return BalanceBreakdown(counted: counted, workdays: workdays, perDay: perDays.count == 1 ? perDays.first : nil, base: base,
                                absences: absences, holidays: holidays, expected: expectedSum, worked: workedSum,
                                since: sinceDate, sinceBalance: sinceBalance)
    }
}

/// One day of the month's running-balance chart.
public struct BalancePoint: Equatable, Sendable, Identifiable {
    public var id: LocalDate { date }
    public var date: LocalDate
    /// Rounded, as in Jira (today: tracked so far).
    public var worked: Seconds
    /// The day's fund (after absences).
    public var expected: Seconds
    /// The day's ± in the balance (`Ledger.dayBalance`: today's shortfall only once the working day is over).
    public var diff: Seconds
    /// The month's balance through this day.
    public var running: Seconds
    /// Counts in the balance: from the first day tikjot knows through today. Later days are drawn as empty ticks.
    public var counted: Bool
}

extension Ledger {
    /// The running balance of a month, one point per day — today included, live, with the same rule as
    /// `liveBalance(month, since:)`, so the last counted point equals the month balance shown everywhere else.
    public func runningBalance(month: DateRange, since: LocalDate) -> [BalancePoint] {
        let t = today
        var run: Seconds = 0
        return month.map { d in
            let counted = d >= since && d <= t
            let diff = counted ? dayBalance(d) : 0
            run += diff
            return BalancePoint(date: d, worked: d <= t ? worked(d) : 0, expected: fund(d), diff: diff,
                                running: counted ? run : 0, counted: counted)
        }
    }
}
