import Foundation
import Testing
@testable import TikjotDomain

/// Values from a crafted backup, a deep link or a typo must not trap (security round 2, S3/S4).
@Suite struct BoundsTests {
    @Test func parsingAcceptsOnlyRealDaysWithin1900To2200() {
        #expect(LocalDate("1900-01-01") != nil)
        #expect(LocalDate("2200-12-31") != nil)
        #expect(LocalDate("2024-02-29") != nil)
        for bad in ["1000000-01-01", "1899-12-31", "2201-01-01", "-2026-01-01", "2026-02-30", "2025-02-29",
                    "2026-13-01", "2026-00-10", "+2026-01-01", "2026-1-", "2026--01-01", "٢٠٢٦-01-01", "99999999999999999999-01-01"] {
            #expect(LocalDate(bad) == nil, "\(bad)")
        }
    }

    @Test func componentsAndDatesAreClampedNotTrapped() {
        #expect(LocalDate(year: 1_000_000, month: 1, day: 1).year == 2200)
        #expect(LocalDate(year: -5, month: 1, day: 1).year == 1900)
        let far = Date(timeIntervalSinceReferenceDate: 1e15)
        let x = LocalDate(far, calendar: bratislava)
        #expect(LocalDate.validYears.contains(x.year))
        _ = x.start(in: bratislava)
        _ = x.adding(days: Int.max).adding(months: Int.min)
        _ = x.days(until: LocalDate(year: 1900, month: 1, day: 1))
        _ = LocalDate(year: 2026, month: Int.max, day: Int.min).at(minutes: Int.max / 2, in: bratislava)
        // Iterating up to the last day stops instead of looping.
        #expect(DateRange(d("2200-12-30"), d("2200-12-31")).map { $0 }.count == 2)
    }

    @Test(arguments: [Calendar.Identifier.hebrew, .buddhist, .japanese, .islamicUmmAlQura])
    func nonGregorianSystemCalendarGivesTheSameDays(id: Calendar.Identifier) {
        var c = Calendar(identifier: id)
        c.timeZone = bratislava.timeZone
        let noon = t("2026-10-02 12:00")
        #expect(LocalDate(noon, calendar: c) == d("2026-10-02"))
        #expect(d("2026-10-02").start(in: c) == d("2026-10-02").start(in: bratislava))
        #expect(d("2026-10-02").at(minutes: 510, in: c) == t("2026-10-02 08:30"))
        #expect(Calendar.gregorianCurrent.identifier == .gregorian)
    }

    @Test func badDurationsDontTrap() {
        let e = TimeEntry(start: Date(timeIntervalSinceReferenceDate: -1e300), end: Date(timeIntervalSinceReferenceDate: 1e300))
        #expect(e.duration(now: Date()) == 1_000_000_000_000)
        #expect(WorkSchedulePeriod(effectiveFrom: d("2026-01-01"), dailyHours: .infinity).dailySeconds == 0)
        #expect(WorkSchedulePeriod(effectiveFrom: d("2026-01-01"), dailyHours: 1e300).dailySeconds == 24 * 3600)
    }

    @Test func settingsAreClampedToWhatSettingsOffers() {
        var s = AppSettings()
        s.rounding.unitMinutes = Int.max
        s.autoRefreshMinutes = Int.max
        s.sleepPromptMinutes = Int.min
        s.snapshotsKeep = -3
        s.idleReminderMinutes = Int.max
        s.graceDays = 10_000
        s.utilizationTarget = .nan
        s.longTimerReminderHours = .infinity
        s.openingBalance = OpeningBalance(date: d("2026-01-01"), seconds: Int.max)
        // Rounding never multiplies an unchecked unit.
        #expect(s.rounding.apply(3601) == 3600)
        let c = s.clamped()
        #expect(c.rounding.unitMinutes == 5)
        #expect(c.autoRefreshMinutes == 240 && c.sleepPromptMinutes == 5 && c.snapshotsKeep == 1 && c.idleReminderMinutes == 240)
        #expect(c.graceDays == 28 && c.utilizationTarget == 0.8 && c.longTimerReminderHours == 3)
        #expect(c.openingBalance?.seconds == 360_000_000)
        #expect(AppSettings().clamped() == AppSettings())
    }
}
