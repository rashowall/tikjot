import Testing
@testable import TikjotDomain

@Suite struct FundTests {
    let cal = DayCalendar(
        schedule: .standard,
        holidays: [Holiday(date: d("2026-09-01"), name: "Test holiday")],
        customDays: [CustomDay(date: d("2026-09-02"), name: "Short", hours: 4)],
        absences: [
            Absence(typeId: AbsenceType.doctor.id, date: d("2026-09-03"), unit: .hours, amountSeconds: 3 * 3600),
            Absence(typeId: AbsenceType.vacation.id, date: d("2026-09-04"), unit: .halfDay),
            Absence(typeId: AbsenceType.vacation.id, date: d("2026-09-07"), unit: .day),
            Absence(typeId: AbsenceType.doctor.id, date: d("2026-09-08"), unit: .hours, amountSeconds: 10 * 3600),
        ])

    @Test func dayFunds() {
        #expect(cal.fund(d("2026-09-01")) == 0)            // holiday
        #expect(cal.fund(d("2026-09-02")) == 4 * 3600)     // custom shortened day
        #expect(cal.fund(d("2026-09-03")) == 5 * 3600)     // doctor 3h (§8.2 example)
        #expect(cal.fund(d("2026-09-04")) == 4 * 3600)     // half-day vacation
        #expect(cal.fund(d("2026-09-05")) == 0)            // Saturday
        #expect(cal.fund(d("2026-09-07")) == 0)            // vacation
        #expect(cal.fund(d("2026-09-08")) == 0)            // never negative
        #expect(cal.fund(d("2026-09-09")) == 8 * 3600)
    }

    @Test func effectiveDatedSchedule() {
        var s = WorkSchedule.standard
        s.change(from: d("2026-10-01")) { $0.dailyHours = 6; $0.workdays = [1, 2, 3, 4] }
        let c = DayCalendar(schedule: s)
        #expect(c.fund(d("2026-09-30")) == 8 * 3600)
        #expect(c.fund(d("2026-10-01")) == 6 * 3600)
        #expect(c.fund(d("2026-10-02")) == 0) // Friday no longer a workday
    }
}
