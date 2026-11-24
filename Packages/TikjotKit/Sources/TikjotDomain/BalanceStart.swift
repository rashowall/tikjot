import Foundation

/// Where balances and utilization start counting (audit U2). Fund before the first day tikjot knows about is never a
/// deficit, and a month without any data is "—", not 0 %.
public enum BalanceStart {
    /// The first day tikjot knows about: the opening balance date, an imported history start or the first entry.
    public static func dataStart(opening: OpeningBalance?, historyStarts: [LocalDate], firstEntry: LocalDate?, today: LocalDate) -> LocalDate {
        var candidates = historyStarts
        if let o = opening { candidates.append(o.date) }
        if let f = firstEntry { candidates.append(f) }
        return candidates.min() ?? today
    }

    /// The running balance counts from the configured start (default 1 Jan), never before `dataStart`.
    public static func effective(configured: LocalDate?, dataStart: LocalDate, today: LocalDate) -> LocalDate {
        max(configured ?? today.firstOfYear, dataStart)
    }

    /// The configured start is earlier than your first data: Settings says "Counting from <dataStart>".
    public static func differs(configured: LocalDate?, dataStart: LocalDate, today: LocalDate) -> Bool {
        effective(configured: configured, dataStart: dataStart, today: today) != (configured ?? today.firstOfYear)
    }

    /// The Jira history starts after the running-balance start: days in between have no data (flagged in Settings).
    public static func importStartsLate(historyStart: LocalDate?, configured: LocalDate?, today: LocalDate) -> Bool {
        guard let h = historyStart else { return false }
        return h > (configured ?? today.firstOfYear)
    }

    /// The date a carried-over balance is "as of": the day the imported history starts (or today without one).
    public static func openingDate(historyStart: LocalDate?, today: LocalDate) -> LocalDate {
        min(historyStart ?? today, today)
    }
}

extension Ledger {
    /// Anything tracked or imported in the range (work or breaks).
    public func hasEntries(in range: DateRange) -> Bool {
        range.contains { !entries(on: $0).isEmpty }
    }

    /// Utilization of one month (a past month whole, the current one to date), `nil` ("—") when the month has no
    /// data at all (audit U2).
    public func monthUtilization(_ month: DateRange, since: LocalDate?, through: LocalDate) -> Double? {
        let first = max(month.start, since ?? month.start)
        let last = min(month.end, through)
        guard last >= first else { return nil }
        let r = DateRange(first, last)
        guard hasEntries(in: r) else { return nil }
        return utilization(r)
    }

    /// Year-to-date utilization over the months that have data — a month without any entries doesn't count as 0 %.
    public func utilizationOfMonthsWithData(_ range: DateRange, through: LocalDate) -> Double? {
        guard let window = utilizationWindow(range, through: through) else { return nil }
        let last = window.end
        var fund: Seconds = 0, billable: Seconds = 0
        var m = range.start.firstOfMonth
        while m <= last {
            let r = DateRange(max(m, range.start), min(m.lastOfMonth, last))
            if hasEntries(in: r) {
                fund += utilizationFund(r)
                billable += billableWorked(r)
            }
            m = m.adding(months: 1)
        }
        guard fund > 0 else { return nil }
        return Double(billable) / Double(fund)
    }
}

/// Gentle reminders that depend only on dates (audit U7; the backup reminder U6 was dropped 2026-10-06).
public enum Nudges {
    /// Onboarding import default: the previous month too while it can still be sent, else this month.
    public static func importStart(today: LocalDate, lock: LockPolicy) -> LocalDate {
        let prev = today.firstOfMonth.adding(months: -1)
        return lock.isLocked(prev, today: today) ? today.firstOfMonth : prev
    }

    public enum FirstDay: Equatable { case wait, show, drop }

    /// The one evening nudge after onboarding ("Send today to Jira"): on its day, once working hours are over
    /// (`minutes` and `workdayEnd` in minutes after midnight), only while today isn't in Jira yet. A passed day drops it.
    public static func firstDay(nudgeDay: LocalDate, today: LocalDate, minutes: Int, workdayEnd: Int, todayUnsent: Bool) -> FirstDay {
        if today > nudgeDay { return .drop }
        guard today == nudgeDay, minutes >= workdayEnd, todayUnsent else { return .wait }
        return .show
    }
}
