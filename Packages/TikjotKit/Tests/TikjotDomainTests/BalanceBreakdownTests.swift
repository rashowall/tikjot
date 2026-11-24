import Foundation
import Testing
@testable import TikjotDomain

/// The month-balance tooltip: its parts add up to exactly the balance the UI shows.
@Suite struct BalanceBreakdownTests {
    let p = Project(name: "Payments", color: "tangerine", billable: true)
    let oct = DateRange.month(of: d("2026-10-01"))
    // Oct 2026: Thu 1, Fri 2, Mon 5, Tue 6 (holiday), Wed 7 (doctor 1h), Thu 8, today Fri 9.
    let absences = [Absence(typeId: AbsenceType.doctor.id, date: d("2026-10-07"), unit: .hours, amountSeconds: 3600)]

    func ledger(_ entries: [TimeEntry], now: String, absences: [Absence]? = nil) -> Ledger {
        Ledger(entries: entries, groups: [], projects: [p],
               calendar: DayCalendar(schedule: .standard, holidays: [Holiday(date: d("2026-10-06"), name: "Test holiday")],
                                     absences: absences ?? self.absences),
               rounding: .default, timeCalendar: bratislava, now: t(now))
    }

    var week: [TimeEntry] {
        [entry("2026-10-01 08:00", "2026-10-01 16:00", issue: "1", project: p.id),
         entry("2026-10-02 08:00", "2026-10-02 15:30", issue: "1", project: p.id),
         entry("2026-10-05 08:00", "2026-10-05 16:00", issue: "1", project: p.id),
         entry("2026-10-07 08:00", "2026-10-07 15:00", issue: "1", project: p.id),
         entry("2026-10-08 08:00", "2026-10-08 17:00", issue: "1", project: p.id)]
    }

    @Test func partsAddUpToTheLiveBalance() {
        // Today short and the working day not over: today isn't counted yet (as in liveBalance).
        let l = ledger(week + [entry("2026-10-09 08:00", "2026-10-09 10:00", issue: "1", project: p.id)], now: "2026-10-09 14:00")
        let b = l.balanceBreakdown(month: oct, since: d("2026-10-01"), runningSince: d("2026-10-01"), opening: nil)
        #expect(b.counted == DateRange(d("2026-10-01"), d("2026-10-08")))
        #expect(b.workdays == 5 && b.perDay == 8 * 3600 && b.holidays == 1)
        #expect(b.absences == [.init(typeId: AbsenceType.doctor.id, seconds: 3600)])
        #expect(b.base - b.absences.reduce(0) { $0 + $1.seconds } == b.expected)
        #expect(b.expected == 39 * 3600)
        #expect(b.worked == 39 * 3600 + 30 * 60)
        #expect(b.balance == 30 * 60)
        #expect(b.balance == l.liveBalance(oct, since: d("2026-10-01")))
        // The running balance starts with this month and has no opening: nothing more to say.
        #expect(b.since == nil)
    }

    @Test func todayCountsOnceItsBalanceDoes() {
        // 9h by 14:00: the overtime counts at once, so today is in the sum.
        let l = ledger(week + [entry("2026-10-09 05:00", "2026-10-09 14:00", issue: "1", project: p.id)], now: "2026-10-09 14:00")
        let b = l.balanceBreakdown(month: oct, since: d("2026-10-01"), runningSince: d("2026-10-01"), opening: nil)
        #expect(b.counted?.end == d("2026-10-09") && b.workdays == 6)
        #expect(b.balance == l.liveBalance(oct, since: d("2026-10-01")))
        #expect(b.balance == 30 * 60 + 3600)
        // Evening of a short day: counted, with its minus.
        let e = ledger(week + [entry("2026-10-09 08:00", "2026-10-09 10:00", issue: "1", project: p.id)], now: "2026-10-09 19:00")
        let eb = e.balanceBreakdown(month: oct, since: d("2026-10-01"), runningSince: d("2026-10-01"), opening: nil)
        #expect(eb.balance == e.liveBalance(oct, since: d("2026-10-01")) && eb.balance == 30 * 60 - 6 * 3600)
    }

    @Test func runningBalanceWithOpeningAndEarlierStart() {
        let l = ledger(week, now: "2026-10-09 14:00")
        let opening = OpeningBalance(date: d("2026-10-01"), seconds: 4 * 3600)
        let b = l.balanceBreakdown(month: oct, since: d("2026-10-01"), runningSince: d("2026-10-01"), opening: opening)
        #expect(b.since == d("2026-10-01") && b.sinceBalance == 4 * 3600 + 30 * 60)
        #expect(b.sinceBalance == l.liveCumulativeBalance(since: d("2026-10-01"), opening: opening))
        // A start before the month: shown, the month's own numbers from the data start.
        let early = l.balanceBreakdown(month: oct, since: d("2026-10-01"), runningSince: d("2026-09-28"), opening: nil)
        #expect(early.since == d("2026-09-28") && early.sinceBalance == 30 * 60 - 3 * 8 * 3600)
        // A past month: no running balance line.
        #expect(l.balanceBreakdown(month: DateRange.month(of: d("2026-09-01")), since: d("2026-09-01"), runningSince: d("2026-09-01"), opening: nil).since == nil)
    }

    @Test func absencesAreCappedAtTheDaysHoursAndUnevenDaysHaveNoPerDay() {
        let vacation = Absence(typeId: AbsenceType.vacation.id, date: d("2026-10-08"), unit: .day)
        let long = Absence(typeId: AbsenceType.doctor.id, date: d("2026-10-07"), unit: .hours, amountSeconds: 10 * 3600)
        let l = Ledger(entries: week, groups: [], projects: [p],
                       calendar: DayCalendar(schedule: .standard, customDays: [CustomDay(date: d("2026-10-02"), name: "Short", hours: 4)],
                                             absences: [vacation, long]),
                       rounding: .default, timeCalendar: bratislava, now: t("2026-10-09 14:00"))
        let b = l.balanceBreakdown(month: oct, since: d("2026-10-01"), runningSince: d("2026-10-01"), opening: nil)
        #expect(b.perDay == nil && b.holidays == 0 && b.workdays == 6)
        #expect(b.absences == [.init(typeId: AbsenceType.doctor.id, seconds: 8 * 3600), .init(typeId: AbsenceType.vacation.id, seconds: 8 * 3600)])
        #expect(b.base - 16 * 3600 == b.expected && b.expected == l.fund(DateRange(d("2026-10-01"), d("2026-10-08"))))
        #expect(b.balance == l.liveBalance(oct, since: d("2026-10-01")))
    }

    /// The Month chart: today's tracked time is in today's point (not tomorrow's), and the last point, the KPI
    /// balance and the tooltip's balance are one number.
    @Test func chartIncludesTodayLive() {
        let since = d("2026-10-01")
        // Today 8h 30m by 16:00: +30m overtime counts at once.
        let l = ledger(week + [entry("2026-10-09 07:30", "2026-10-09 16:00", issue: "1", project: p.id)], now: "2026-10-09 16:00")
        let pts = l.runningBalance(month: oct, since: since)
        #expect(pts.count == 31)
        let today = pts.first { $0.date == d("2026-10-09") }!
        #expect(today.counted && today.worked == 8 * 3600 + 30 * 60 && today.expected == 8 * 3600 && today.diff == 30 * 60)
        #expect(pts.last { $0.counted }?.date == d("2026-10-09"))
        #expect(!pts.first { $0.date == d("2026-10-10") }!.counted)
        let balance = l.liveBalance(oct, since: since)
        #expect(today.running == balance && balance == 3600)
        #expect(l.balanceBreakdown(month: oct, since: since, runningSince: since, opening: nil).balance == balance)

        // Exactly 8h today: worked shows on today's point, the balance doesn't move.
        let eight = ledger(week + [entry("2026-10-09 07:00", "2026-10-09 15:00", issue: "1", project: p.id)], now: "2026-10-09 15:30")
        let t8 = eight.runningBalance(month: oct, since: since).first { $0.date == d("2026-10-09") }!
        #expect(t8.worked == 8 * 3600 && t8.diff == 0 && t8.running == eight.liveBalance(oct, since: since))

        // A short day before its end: tracked time shows, no minus yet; the three numbers still agree.
        let short = ledger(week + [entry("2026-10-09 08:00", "2026-10-09 10:00", issue: "1", project: p.id)], now: "2026-10-09 14:00")
        let ts = short.runningBalance(month: oct, since: since).first { $0.date == d("2026-10-09") }!
        #expect(ts.worked == 2 * 3600 && ts.diff == 0)
        #expect(ts.running == short.liveBalance(oct, since: since))
        #expect(ts.running == short.balanceBreakdown(month: oct, since: since, runningSince: since, opening: nil).balance)

        // Days before the data start don't count.
        let late = l.runningBalance(month: oct, since: d("2026-10-05"))
        #expect(!late[0].counted && late[0].running == 0)
        #expect(late.last { $0.counted }?.running == l.liveBalance(oct, since: d("2026-10-05")))
    }

    @Test func nothingCountedYet() {
        let l = ledger([], now: "2026-10-01 09:00", absences: [])
        let b = l.balanceBreakdown(month: oct, since: d("2026-10-01"), runningSince: d("2026-10-01"), opening: nil)
        #expect(b.counted == nil && b.expected == 0 && b.worked == 0 && b.balance == 0 && b.since == nil)
    }
}
