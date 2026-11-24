import Foundation
import Testing
@testable import TikjotDomain

@Suite struct FormattingTests {
    @Test(arguments: [("1h", 3600), ("1h 30m", 5400), ("1:30", 5400), ("90m", 5400), ("90", 5400),
                      ("1.5", 5400), ("1,5h", 5400), ("2", 7200), ("45m", 2700), ("0", 0)])
    func parse(input: String, expected: Int) {
        #expect(DurationFormat.parse(input) == expected)
    }

    @Test func bad() {
        #expect(DurationFormat.parse("abc") == nil)
        #expect(DurationFormat.parse("1:75") == nil)
    }

    @Test func format() {
        #expect(DurationFormat.hm(5400) == "1h 30m")
        #expect(DurationFormat.hm(0) == "0m")
        #expect(DurationFormat.hm(2520) == "42m")
        #expect(DurationFormat.hm(3900) == "1h 05m")
        #expect(DurationFormat.hm(-2520) == "−42m")
        #expect(DurationFormat.hm(-30) == "0m")
        #expect(DurationFormat.padded(2520) == "0h 42m")
        #expect(DurationFormat.padded(0) == "0h 00m")
        #expect(DurationFormat.signed(-1260) == "−21m")
        #expect(DurationFormat.signed(-2520) == "−42m")
        #expect(DurationFormat.signed(0) == "0m")
        #expect(DurationFormat.signed(-6000) == "−1h 40m")
        #expect(DurationFormat.percent(0.714) == "71%")
        #expect(DurationFormat.signed(15540) == "+4h 19m")
        #expect(DurationFormat.clock(4980) == "1:23")
        #expect(DurationFormat.short(2700) == "45m")
    }

    @Test(arguments: [("1020", 620), ("10:20", 620), ("10.20", 620), ("9", 540), ("930", 570), ("24:00", 1440)])
    func timeOfDay(input: String, expected: Int) {
        #expect(TimeOfDayParser.parse(input) == expected)
    }

    /// Popover entry card: what Done (or focus leaving) does with the text still in START / END / LENGTH.
    @Test func typedFieldCommit() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Bratislava")!
        let day = LocalDate(year: 2026, month: 10, day: 7)
        let nine = day.at(minutes: 540, in: cal)
        #expect(TypedField.time("1020", current: nine, day: day, calendar: cal) == .set(day.at(minutes: 620, in: cal)))
        #expect(TypedField.time("09:00", current: nine, day: day, calendar: cal) == .keep)
        #expect(TypedField.time("25:00", current: nine, day: day, calendar: cal) == .invalid)
        #expect(TypedField.time("abc", current: nine, day: day, calendar: cal) == .invalid)
        // The owner's case: "2h 2m" typed into LENGTH, then Done without ↩.
        #expect(TypedField.length("2h 2m", current: 3600, range: 60...Int.max) == .set(7320))
        #expect(TypedField.length("1h", current: 3600, range: 60...Int.max) == .keep)
        #expect(TypedField.length("20s", current: 3600, range: 60...Int.max) == .invalid)
        #expect(TypedField.length("0", current: 3600, range: 60...Int.max) == .invalid)
        #expect(TypedField.length("30", current: 3600, range: 3600...7200) == .keep)   // clamped to the range
    }

    @Test func palette() {
        #expect(ProjectPalette.nextUnused([]) == "blue")
        #expect(ProjectPalette.nextUnused(["blue", "amber"]) == "green")
        #expect(ProjectPalette.nextUnused(ProjectPalette.names) == "blue")
    }
}

@Suite struct LockingTests {
    let lock = LockPolicy(graceDays: 5)

    @Test func graceWindow() {
        #expect(!lock.isLocked(d("2026-09-15"), today: d("2026-10-05")))
        #expect(lock.isLocked(d("2026-09-15"), today: d("2026-10-06")))
        #expect(lock.isLocked(d("2026-08-31"), today: d("2026-10-01")))
        #expect(!lock.isLocked(d("2026-10-01"), today: d("2026-10-20")))
        #expect(lock.editableUntil(d("2026-09-15")) == d("2026-10-05"))
        #expect(!lock.canSend(d("2026-10-21"), today: d("2026-10-20")))
        #expect(lock.canEditAbsences(on: d("2026-12-24"), today: d("2026-10-20")))
    }
}


@Suite struct KnownFromTests {
    @Test func daysBeforeHistoryAreNotMissed() {
        let l = Ledger(entries: [], groups: [], projects: [], calendar: DayCalendar(schedule: .standard), rounding: .default,
                       timeCalendar: bratislava, now: t("2026-10-04 12:00"), knownFrom: d("2026-10-01"))
        #expect(l.dayStatus(d("2026-09-30"), lock: LockPolicy()) == .none)
        #expect(l.dayStatus(d("2026-10-02"), lock: LockPolicy()) == .missed)
    }
}

@Suite struct WeekStartTests {
    @Test func weekStartFollowsTheRegion() {
        let wed = LocalDate("2026-10-07")!
        #expect(wed.startOfWeek(startingOn: 1) == LocalDate("2026-10-05")!) // Monday
        #expect(wed.startOfWeek(startingOn: 7) == LocalDate("2026-10-04")!) // Sunday
        #expect(wed.startOfWeek(startingOn: 6) == LocalDate("2026-10-03")!) // Saturday
        let sun = LocalDate("2026-10-04")!
        #expect(sun.startOfWeek(startingOn: 7) == sun)
        #expect(sun.startOfWeek(startingOn: 1) == LocalDate("2026-09-28")!)
    }
}
