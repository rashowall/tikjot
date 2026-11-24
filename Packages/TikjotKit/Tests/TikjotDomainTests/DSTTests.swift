import Foundation
import Testing
@testable import TikjotDomain

/// Daylight saving time in Europe/Bratislava: autumn Sun 25 Oct 2026 03:00 CEST → 02:00 CET (a 25-hour day),
/// spring Sun 29 Mar 2026 02:00 CET → 03:00 CEST (a 23-hour day). Durations are elapsed time, days are wall-clock days.
@Suite struct DSTTests {
    /// An instant given in UTC — the ground truth the local times are checked against.
    func utc(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    let p = Project(name: "Payments", color: "tangerine", billable: true)

    func ledger(_ entries: [TimeEntry], now: Date, schedule: WorkSchedule = .standard, cal: Calendar = bratislava) -> Ledger {
        Ledger(entries: entries, groups: [], projects: [p], calendar: DayCalendar(schedule: schedule), rounding: .default,
               timeCalendar: cal, now: now)
    }

    /// Every weekday a workday (so the DST Sunday has a fund).
    var sevenDays: WorkSchedule {
        var s = WorkSchedule.standard
        s.change(from: d("2000-01-01")) { $0.workdays = [1, 2, 3, 4, 5, 6, 7] }
        return s
    }

    // MARK: Days and durations

    @Test func localTimesAreTheRightInstants() {
        #expect(t("2026-10-25 01:30") == utc("2026-10-24 23:30"))   // CEST, +02:00
        #expect(t("2026-10-25 03:30") == utc("2026-10-25 02:30"))   // CET, +01:00
        #expect(t("2026-03-29 01:30") == utc("2026-03-29 00:30"))   // CET
        #expect(t("2026-03-29 03:30") == utc("2026-03-29 01:30"))   // CEST
    }

    @Test func dayLengths() {
        let oct = d("2026-10-25"), mar = d("2026-03-29")
        #expect(oct.end(in: bratislava).timeIntervalSince(oct.start(in: bratislava)) == 25 * 3600)
        #expect(mar.end(in: bratislava).timeIntervalSince(mar.start(in: bratislava)) == 23 * 3600)
        #expect(oct.start(in: bratislava) == utc("2026-10-24 22:00"))
        #expect(oct.end(in: bratislava) == utc("2026-10-25 23:00"))
        // Both 02:30s (summer and winter time) are on 25 Oct.
        #expect(LocalDate(utc("2026-10-25 00:30"), calendar: bratislava) == oct)
        #expect(LocalDate(utc("2026-10-25 01:30"), calendar: bratislava) == oct)
        #expect(LocalDate(utc("2026-10-24 21:59"), calendar: bratislava) == d("2026-10-24"))
        #expect(LocalDate(utc("2026-10-24 22:00"), calendar: bratislava) == oct)
        #expect(oct.at(minutes: 9 * 60, in: bratislava) == utc("2026-10-25 08:00"))
        #expect(mar.at(minutes: 9 * 60, in: bratislava) == utc("2026-03-29 07:00"))
    }

    @Test func entryAcrossTheChangeLastsElapsedTime() {
        let e = entry("2026-10-25 01:30", "2026-10-25 03:30", issue: "1", project: p.id)
        #expect(e.duration(now: t("2026-10-26 12:00")) == 3 * 3600)
        let l = ledger([e], now: t("2026-10-26 12:00"))
        #expect(l.raw(d("2026-10-25")) == 3 * 3600)
        #expect(l.worked(d("2026-10-25")) == 3 * 3600)
        #expect(l.billableWorked(d("2026-10-25")) == 3 * 3600)
        #expect(l.lines(on: d("2026-10-25")).first?.started == utc("2026-10-24 23:30"))
        // Spring: 01:30 → 03:30 is one hour.
        let s = entry("2026-03-29 01:30", "2026-03-29 03:30", issue: "1", project: p.id)
        #expect(ledger([s], now: t("2026-03-30 12:00")).worked(d("2026-03-29")) == 3600)
    }

    @Test func clockPositionOnTheDay() {
        let oct = d("2026-10-25"), mar = d("2026-03-29")
        #expect(oct.clockSeconds(t("2026-10-25 09:00"), in: bratislava) == 9 * 3600)
        #expect(oct.clockSeconds(t("2026-10-25 01:30"), in: bratislava) == 1.5 * 3600)
        #expect(oct.clockSeconds(utc("2026-10-25 01:30"), in: bratislava) == 2.5 * 3600)   // the second 02:30
        #expect(oct.clockSeconds(oct.end(in: bratislava), in: bratislava) == 24 * 3600)
        #expect(mar.clockSeconds(t("2026-03-29 09:00"), in: bratislava) == 9 * 3600)
        #expect(mar.clockSeconds(mar.end(in: bratislava), in: bratislava) == 24 * 3600)
        #expect(d("2026-10-01").clockSeconds(t("2026-10-01 13:15"), in: bratislava) == 13.25 * 3600)
    }

    // MARK: Midnight

    @Test func entryAcrossMidnightBeforeTheChange() {
        // 24 Oct 22:00 CEST → 25 Oct 04:00 CET: 7 h, 2 h on Saturday and 5 h on Sunday (4 h on the clock).
        let e = entry("2026-10-24 22:00", "2026-10-25 04:00", project: p.id)
        let parts = EntryOps.splitAtMidnight(e, now: t("2026-10-26 12:00"), calendar: bratislava)
        #expect(parts.map { $0.duration(now: t("2026-10-26 12:00")) } == [2 * 3600, 5 * 3600])
        #expect(parts[1].start == d("2026-10-25").start(in: bratislava))
        let l = ledger([e], now: t("2026-10-26 12:00"))
        #expect(l.worked(d("2026-10-24")) == 2 * 3600)
        #expect(l.worked(d("2026-10-25")) == 5 * 3600)
        #expect(l.worked(DateRange(d("2026-10-24"), d("2026-10-25"))) == 7 * 3600)
        let n = EntryOps.normalizeMidnight(e, calendar: bratislava)
        #expect(n.updated.first?.end == d("2026-10-25").start(in: bratislava))
        #expect(n.inserted.map { $0.duration(now: Date()) } == [5 * 3600])
        // And across the next midnight (25/26 Oct, in winter time): 1 h + 1 h.
        let e2 = entry("2026-10-25 23:00", "2026-10-26 01:00", project: p.id)
        let l2 = ledger([e2], now: t("2026-10-26 12:00"))
        #expect(l2.worked(d("2026-10-25")) == 3600 && l2.worked(d("2026-10-26")) == 3600)
    }

    @Test func runningTimerAcrossTheChange() {
        // Started Sat 23:00 CEST, now Sun 09:00 CET: 11 h, 1 h on Saturday, 10 h on Sunday.
        var r = entry("2026-10-24 23:00", nil, issue: "1", project: p.id)
        r.end = nil
        let now = t("2026-10-25 09:00")
        #expect(r.duration(now: now) == 11 * 3600)
        let l = ledger([r], now: now)
        #expect(l.raw(d("2026-10-24")) == 3600)
        #expect(l.raw(d("2026-10-25")) == 10 * 3600)
        #expect(l.lines(on: d("2026-10-25")).first?.containsRunning == true)
        // Sunday has no fund in the standard week: all of it is overtime, at once.
        #expect(l.dayBalance(d("2026-10-25")) == 10 * 3600)

        // Waking up on Sunday: the timer is stored per day.
        let parts = AwayOps.splitRunning(r, today: d("2026-10-25"), calendar: bratislava)
        #expect(parts.count == 2)
        #expect(parts[0].end == d("2026-10-25").start(in: bratislava) && parts[0].duration(now: now) == 3600)
        #expect(parts[1].isRunning && parts[1].start == d("2026-10-25").start(in: bratislava))
        #expect(parts[1].duration(now: now) == 10 * 3600)
        // "Stop at 03:30" (winter time) — the part running then ends there; nothing after it.
        let stop = AwayOps.stop(at: t("2026-10-25 03:30"), running: parts[1], entries: parts)
        #expect(stop.updated.count == 1 && stop.updated[0].end == t("2026-10-25 03:30"))
        #expect(stop.updated[0].duration(now: now) == 4 * 3600 + 1800 && stop.deleted.isEmpty)

        #expect(AwayOps.dayChanged(from: t("2026-10-24 23:59"), to: t("2026-10-25 00:01"), calendar: bratislava))
        // The repeated hour is the same day.
        #expect(!AwayOps.dayChanged(from: utc("2026-10-25 00:30"), to: utc("2026-10-25 01:30"), calendar: bratislava))
    }

    @Test func runningTimerAcrossSpringChange() {
        var r = entry("2026-03-28 23:00", nil, project: p.id)
        r.end = nil
        let now = t("2026-03-29 09:00")
        let l = ledger([r], now: now)
        #expect(l.raw(d("2026-03-28")) == 3600)
        #expect(l.raw(d("2026-03-29")) == 8 * 3600)   // 00:00 → 09:00 on the clock, 8 h elapsed
        let parts = AwayOps.splitRunning(r, today: d("2026-03-29"), calendar: bratislava)
        #expect(parts.map { $0.duration(now: now) } == [3600, 8 * 3600])
    }

    // MARK: Aggregation, fund, balance

    @Test func weekAndMonthAggregation() {
        let es = [
            entry("2026-10-23 08:00", "2026-10-23 16:00", issue: "1", project: p.id),   // Fri
            entry("2026-10-25 01:30", "2026-10-25 03:30", issue: "1", project: p.id),   // Sun, 3 h
            entry("2026-10-26 08:00", "2026-10-26 16:00", issue: "1", project: p.id),   // Mon
        ]
        let l = ledger(es, now: t("2026-10-27 12:00"))
        let week = DateRange.week(of: d("2026-10-25"))
        #expect(week == DateRange(d("2026-10-19"), d("2026-10-25")))
        #expect(l.worked(week) == 11 * 3600)
        #expect(l.worked(DateRange.month(of: d("2026-10-25"))) == 19 * 3600)
        #expect(l.fund(d("2026-10-25")) == 0)
        #expect(l.fund(DateRange.month(of: d("2026-10-01"))) == 22 * 8 * 3600)   // 22 workdays, DST or not
        #expect(l.fund(DateRange.month(of: d("2026-03-01"))) == 22 * 8 * 3600)
    }

    @Test func fundOfTheLongAndShortDayIsTheContract() {
        // With Sunday as a workday the 25-hour and the 23-hour day expect 8 h like any other.
        let es = [entry("2026-10-25 08:00", "2026-10-25 16:00", project: p.id),
                  entry("2026-03-29 08:00", "2026-03-29 16:00", project: p.id)]
        let l = ledger(es, now: t("2026-10-27 12:00"), schedule: sevenDays)
        #expect(l.fund(d("2026-10-25")) == 8 * 3600 && l.fund(d("2026-03-29")) == 8 * 3600)
        #expect(l.dayBalance(d("2026-10-25")) == 0 && l.dayBalance(d("2026-03-29")) == 0)

        // Today's linear fund runs 08:00 → 16:30 on the clock: at 12:15 CET half of it is used.
        let live = ledger([], now: t("2026-10-25 12:15"), schedule: sevenDays)
        #expect(live.liveFund(d("2026-10-25")) == 4 * 3600)
        // The shortfall only counts after 16:30 local (winter time).
        let short = [entry("2026-10-25 08:00", "2026-10-25 12:00", project: p.id)]
        #expect(ledger(short, now: t("2026-10-25 16:29"), schedule: sevenDays).dayBalance(d("2026-10-25")) == 0)
        #expect(ledger(short, now: t("2026-10-25 16:31"), schedule: sevenDays).dayBalance(d("2026-10-25")) == -4 * 3600)
    }

    // MARK: Editing helpers

    @Test func snappingKeepsWallClockTime() {
        // After the change the day is an hour longer (shorter): snapping must stay on the clock.
        #expect(EntryOps.snap(t("2026-10-25 09:02"), calendar: bratislava) == t("2026-10-25 09:00"))
        #expect(EntryOps.snap(t("2026-10-25 23:58"), calendar: bratislava) == d("2026-10-26").start(in: bratislava))
        #expect(EntryOps.snap(t("2026-03-29 09:03"), calendar: bratislava) == t("2026-03-29 09:05"))
        // In the repeated hour each 02:3x snaps within its own hour.
        #expect(EntryOps.snap(utc("2026-10-25 00:32"), calendar: bratislava) == utc("2026-10-25 00:30"))
        #expect(EntryOps.snap(utc("2026-10-25 01:32"), calendar: bratislava) == utc("2026-10-25 01:30"))
        #expect(EntryOps.snap(t("2026-10-01 09:02"), calendar: bratislava) == t("2026-10-01 09:00"))
    }

    @Test func placementAndGapsOnTheLongDay() {
        let (s, e) = EntryOps.placementForNewEntry(on: d("2026-10-25"), entries: [], workdayStartMinutes: 8 * 60,
                                                   now: t("2026-10-27 12:00"), calendar: bratislava)
        #expect(s == t("2026-10-25 08:00") && e == t("2026-10-25 08:30"))
        let es = [entry("2026-10-25 01:00", "2026-10-25 01:30", project: p.id),
                  entry("2026-10-25 03:00", "2026-10-25 03:30", project: p.id)]
        let gaps = EntryOps.gaps(es, from: t("2026-10-25 01:00"), to: t("2026-10-25 03:30"), now: t("2026-10-27 12:00"), minimum: 5 * 60)
        #expect(gaps.map(\.seconds) == [Int(2.5 * 3600)])
    }

    // MARK: Other zones

    @Test func newYorkFallBack() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        // Sun 1 Nov 2026: 02:00 EDT → 01:00 EST. 00:30 EDT (04:30 UTC) → 03:30 EST (08:30 UTC) = 4 h.
        let e = TimeEntry(start: utc("2026-11-01 04:30"), end: utc("2026-11-01 08:30"), projectId: p.id)
        let l = ledger([e], now: utc("2026-11-02 12:00"), cal: ny)
        #expect(l.worked(d("2026-11-01")) == 4 * 3600)
        #expect(d("2026-11-01").end(in: ny).timeIntervalSince(d("2026-11-01").start(in: ny)) == 25 * 3600)
        #expect(EntryOps.snap(utc("2026-11-01 14:02"), calendar: ny) == utc("2026-11-01 14:00"))   // 09:02 EST
    }

    @Test func zoneWhereMidnightIsSkipped() {
        // Chile springs forward at 24:00: Sun 6 Sep 2026 starts at 01:00 (−03), a 23-hour day.
        var cl = Calendar(identifier: .gregorian)
        cl.timeZone = TimeZone(identifier: "America/Santiago")!
        let day = d("2026-09-06")
        let start = day.start(in: cl)
        #expect(LocalDate(start, calendar: cl) == day)
        #expect(LocalDate(start.addingTimeInterval(-1), calendar: cl) == d("2026-09-05"))
        // 5 Sep 23:00 (−04, 03:00 UTC) → 6 Sep 02:00 (−03, 05:00 UTC): 2 h, 1 h on each day.
        let e = TimeEntry(start: utc("2026-09-06 03:00"), end: utc("2026-09-06 05:00"), projectId: p.id)
        let l = ledger([e], now: utc("2026-09-07 12:00"), cal: cl)
        #expect(l.worked(d("2026-09-05")) == 3600 && l.worked(day) == 3600)
    }
}
