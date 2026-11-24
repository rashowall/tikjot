import Foundation
import Testing
@testable import TikjotDomain

/// The running period is compared with what was expected to date, by the balance's rule (owner 2026-10-07:
/// "the current week always looks behind"). Standard schedule: Mon–Fri 8h, 08:00–16:30.
@Suite struct PeriodSoFarTests {
    // Mon 5 – Sun 11 Oct 2026.
    let week = DateRange.week(of: d("2026-10-07"))

    func ledger(_ entries: [TimeEntry], now: String, holidays: [Holiday] = [], absences: [Absence] = []) -> Ledger {
        Ledger(entries: entries, groups: [], projects: [],
               calendar: DayCalendar(schedule: .standard, holidays: holidays, customDays: [], absences: absences),
               rounding: .off, timeCalendar: bratislava, now: t(now))
    }

    /// `hours` worked from 08:00 on each day.
    func worked(_ days: [String: Double]) -> [TimeEntry] {
        days.map { day, h in
            let end = 8 * 60 + Int(h * 60)
            return entry("\(day) 08:00", "\(day) \(String(format: "%02d:%02d", end / 60, end % 60))", issue: "1")
        }
    }

    func expectAgrees(_ l: Ledger, _ r: DateRange, since: LocalDate? = nil) {
        let s = l.soFar(r, since: since)
        #expect(s.balance == l.liveBalance(r, since: since))
        #expect(s.expected == l.expectedSoFar(r, since: since))
    }

    @Test func wednesdayAfternoon() {
        // Mon 8h, Tue 8h, Wed 5h so far at 13:00 (the day isn't over: no shortfall yet).
        let l = ledger(worked(["2026-10-05": 8, "2026-10-06": 8]) + [entry("2026-10-07 08:00", nil, issue: "1")], now: "2026-10-07 13:00")
        let s = l.soFar(week)
        #expect(s.worked == 21 * 3600)
        #expect(s.expected == 21 * 3600)
        #expect(s.full == 40 * 3600)
        #expect(s.isRunning && s.hasMoreToCome)
        #expect(s.balance == 0)
        expectAgrees(l, week)
        // Today counts what is worked until the working day ends …
        #expect(l.expectedSoFar(d("2026-10-07")) == 5 * 3600)
        #expect(l.expectedSoFar(d("2026-10-08")) == 0)
        // … and its whole fund after it (a shortfall of 3h then).
        let evening = ledger(worked(["2026-10-05": 8, "2026-10-06": 8, "2026-10-07": 5]), now: "2026-10-07 17:00")
        #expect(evening.soFar(week).expected == 24 * 3600)
        #expect(evening.soFar(week).balance == -3 * 3600)
        expectAgrees(evening, week)
    }

    @Test func overtimeTodayCountsAtOnce() {
        let l = ledger(worked(["2026-10-05": 8, "2026-10-06": 9.5]), now: "2026-10-06 15:00")
        let s = l.soFar(week)
        #expect(s.expected == 16 * 3600)
        #expect(s.balance == 90 * 60)
        expectAgrees(l, week)
    }

    @Test func mondayMorning() {
        let nothing = ledger([], now: "2026-10-05 07:30")
        let s = nothing.soFar(week)
        #expect(s.worked == 0 && s.expected == 0 && s.balance == 0)
        #expect(s.full == 40 * 3600 && s.isRunning)
        expectAgrees(nothing, week)

        let started = ledger(worked(["2026-10-05": 1]), now: "2026-10-05 09:00")
        #expect(started.soFar(week).expected == 3600)
        #expect(started.soFar(week).balance == 0)
        expectAgrees(started, week)
    }

    @Test func fridayAfterHours() {
        let l = ledger(worked(["2026-10-05": 8, "2026-10-06": 8, "2026-10-07": 8, "2026-10-08": 8, "2026-10-09": 6]), now: "2026-10-09 18:00")
        let s = l.soFar(week)
        #expect(s.worked == 38 * 3600)
        #expect(s.expected == 40 * 3600)
        #expect(!s.hasMoreToCome)          // the weekend expects nothing
        #expect(s.balance == -2 * 3600)
        expectAgrees(l, week)
    }

    @Test func weekWithHolidayAndVacation() {
        // Tue a public holiday, Thu a vacation day; Fri 10:00 with 2h worked.
        let l = ledger(worked(["2026-10-05": 8, "2026-10-07": 8.5, "2026-10-09": 2]), now: "2026-10-09 10:00",
                       holidays: [Holiday(date: d("2026-10-06"), name: "Holiday")],
                       absences: [Absence(typeId: AbsenceType.vacation.id, date: d("2026-10-08"), unit: .day)])
        let s = l.soFar(week)
        #expect(s.full == 24 * 3600)
        #expect(s.expected == 18 * 3600)   // 8 + 0 + 8 + 0 + 2 (today, so far)
        #expect(s.worked == 18 * 3600 + 30 * 60)
        #expect(s.balance == 30 * 60)
        expectAgrees(l, week)
        // The vacation day expects nothing even on the day itself.
        let onVacation = ledger(worked(["2026-10-05": 8]), now: "2026-10-08 12:00",
                                absences: [Absence(typeId: AbsenceType.vacation.id, date: d("2026-10-08"), unit: .day)])
        #expect(onVacation.expectedSoFar(d("2026-10-08")) == 0)
    }

    @Test func pastAndFuturePeriods() {
        let l = ledger(worked(["2026-10-05": 8]), now: "2026-10-14 12:00")
        let past = l.soFar(week)
        #expect(!past.isRunning && !past.hasMoreToCome)
        #expect(past.expected == past.full)
        #expect(past.balance == l.liveBalance(week))
        let future = l.soFar(DateRange.week(of: d("2026-10-21")))
        #expect(!future.isRunning && future.expected == 0 && future.worked == 0 && future.full == 40 * 3600)
    }

    @Test func sinceSkipsUnknownDays() {
        // tikjot knows the user from Wednesday: Mon and Tue count neither way.
        let l = ledger(worked(["2026-10-05": 3, "2026-10-07": 8]), now: "2026-10-08 10:00")
        let s = l.soFar(week, since: d("2026-10-07"))
        #expect(s.worked == 8 * 3600)
        #expect(s.full == 24 * 3600)
        #expect(s.expected == 8 * 3600)
        expectAgrees(l, week, since: d("2026-10-07"))
    }

    @Test func monthToDateMatchesMonthBalance() {
        let month = DateRange.month(of: d("2026-10-01"))
        let l = ledger(worked(["2026-10-01": 8, "2026-10-02": 7, "2026-10-05": 8, "2026-10-06": 8, "2026-10-07": 4]), now: "2026-10-07 12:00")
        let s = l.soFar(month)
        #expect(s.expected == 36 * 3600)   // Thu 1, Fri 2, Mon 5, Tue 6 and today's 4h
        #expect(s.full == l.fund(month))
        #expect(s.balance == -3600)
        expectAgrees(l, month)
    }
}
