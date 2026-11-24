import Foundation
import Testing
@testable import TikjotDomain

/// Utilization = billable worked ÷ full fund (owner 2026-10-07): holidays and company days off leave the fund,
/// absences don't — they lower utilization; overtime takes it above 100 %.
@Suite struct UtilizationTests {
    let billable = Project(name: "Payments", color: "tangerine", billable: true)
    let internalP = Project(name: "Internal", color: "slate", billable: false)
    // Mon 5 – Fri 9 Oct 2026.
    let week = DateRange(d("2026-10-05"), d("2026-10-09"))

    func ledger(_ entries: [TimeEntry], now: String = "2026-10-12 12:00", holidays: [Holiday] = [], customDays: [CustomDay] = [],
                absences: [Absence] = []) -> Ledger {
        Ledger(entries: entries, groups: [], projects: [billable, internalP],
               calendar: DayCalendar(schedule: .standard, holidays: holidays, customDays: customDays, absences: absences),
               rounding: .default, timeCalendar: bratislava, now: t(now))
    }

    func days(_ ds: [String], hours: Int = 8, project: Project? = nil) -> [TimeEntry] {
        ds.map { entry("\($0) 08:00", "\($0) \(String(format: "%02d", 8 + hours)):00", issue: "1", project: (project ?? billable).id) }
    }

    @Test func fullFundIgnoresAbsencesButNotHolidays() {
        let cal = DayCalendar(schedule: .standard, holidays: [Holiday(date: d("2026-10-06"), name: "Holiday")],
                              customDays: [CustomDay(date: d("2026-10-07"), name: "Company day off", hours: 0),
                                           CustomDay(date: d("2026-10-08"), name: "Short", hours: 4)],
                              absences: [Absence(typeId: AbsenceType.vacation.id, date: d("2026-10-09"), unit: .day),
                                         Absence(typeId: AbsenceType.doctor.id, date: d("2026-10-05"), unit: .hours, amountSeconds: 2 * 3600)])
        #expect(cal.fullFund(d("2026-10-05")) == 8 * 3600)   // doctor 2h: still 8h
        #expect(cal.fullFund(d("2026-10-06")) == 0)          // public holiday
        #expect(cal.fullFund(d("2026-10-07")) == 0)          // company day off
        #expect(cal.fullFund(d("2026-10-08")) == 4 * 3600)   // shortened company day
        #expect(cal.fullFund(d("2026-10-09")) == 8 * 3600)   // vacation: still 8h
        #expect(cal.fullFund(d("2026-10-10")) == 0)          // Saturday
        #expect(cal.fullFund(week) == 20 * 3600)
        #expect(cal.fund(week) == 10 * 3600)                 // the balance's fund does take absences off
    }

    @Test func vacationLowersUtilization() {
        let full = ledger(days(["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09"]))
        #expect(full.utilization(week) == 1.0)
        // Friday on vacation, the other four days fully billable: 32h of 40h.
        let vac = ledger(days(["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08"]),
                         absences: [Absence(typeId: AbsenceType.vacation.id, date: d("2026-10-09"), unit: .day)])
        #expect(vac.utilization(week) == 0.8)
        // The balance doesn't mind the vacation.
        #expect(vac.balance(week) == 0)
        // A doctor's hours lower it too.
        let doc = ledger(days(["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08"]) + days(["2026-10-09"], hours: 6),
                         absences: [Absence(typeId: AbsenceType.doctor.id, date: d("2026-10-09"), unit: .hours, amountSeconds: 2 * 3600)])
        #expect(doc.utilization(week) == 38.0 / 40.0)
    }

    @Test func holidayAndCompanyDayOffDoNot() {
        let l = ledger(days(["2026-10-05", "2026-10-07", "2026-10-08"]),
                       holidays: [Holiday(date: d("2026-10-06"), name: "Holiday")],
                       customDays: [CustomDay(date: d("2026-10-09"), name: "Company day off", hours: 0)])
        #expect(l.utilization(week) == 1.0)
    }

    @Test func overtimeGoesAbove100AndNonBillableDoesNotCount() {
        let over = ledger(days(["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09"], hours: 10))
        #expect(over.utilization(week) == 1.25)
        let mixed = ledger(days(["2026-10-05", "2026-10-06"]) + days(["2026-10-07", "2026-10-08", "2026-10-09"], project: internalP))
        #expect(mixed.utilization(week) == 0.4)
    }

    @Test func currentMonthIsToDateWithTodayLive() {
        // Today Fri 9 Oct at 12:15 (working day 08:00–16:30, half gone): Mon–Thu 8h billable, today 4h so far.
        let l = ledger(days(["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08"]) + [entry("2026-10-09 08:15", "2026-10-09 12:15", issue: "1", project: billable.id)],
                       now: "2026-10-09 12:15")
        #expect(l.utilizationFund(week) == 36 * 3600)
        #expect(l.utilization(week) == 1.0)
        // Future days never count, with or without `through`.
        #expect(l.utilization(DateRange(d("2026-10-05"), d("2026-10-16"))) == 1.0)
        // Through yesterday: the four whole days.
        #expect(l.utilization(week, through: d("2026-10-08")) == 1.0)
        let month = DateRange.month(of: d("2026-10-01"))
        // 1–2 Oct have no entries: they count (the month has data), 16h of fund with nothing billable.
        #expect(l.monthUtilization(month, since: nil, through: l.today) == 36.0 / 52.0)
        // From the data start only.
        #expect(l.monthUtilization(month, since: d("2026-10-05"), through: l.today) == 1.0)
    }

    @Test func pastMonthIsTheWholeMonth() {
        // September 2026: 22 workdays; 11 billable days of 8h, one vacation week (5 days) → 88 / 176 = 50 %.
        let sept = DateRange.month(of: d("2026-09-01"))
        let workdays = DayCalendar(schedule: .standard).workdays(in: sept)
        #expect(workdays.count == 22)
        let vacation = workdays[11..<16].map { Absence(typeId: AbsenceType.vacation.id, date: $0, unit: .day) }
        let l = ledger(days(workdays.prefix(11).map(\.description)), absences: Array(vacation))
        #expect(l.monthUtilization(sept, since: nil, through: l.today) == 0.5)
        #expect(l.utilizationOfMonthsWithData(DateRange(d("2026-01-01"), d("2026-12-31")), through: l.today) == 0.5)   // October has no data: not a 0 % month
    }
}
