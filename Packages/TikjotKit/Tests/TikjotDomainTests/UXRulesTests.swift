import Foundation
import Testing
@testable import TikjotDomain

/// Audit 2026-10-06 (U1–U7, S-wake): the rules every screen shares.
@Suite struct NeedsYouTests {
    let p = Project(name: "Payments", color: "blue", billable: true)

    func ledger(_ entries: [TimeEntry], groups: [WorklogGroup] = [], now: String = "2026-10-06 18:00", knownFrom: String? = "2026-10-01") -> Ledger {
        Ledger(entries: entries, groups: groups, projects: [p], calendar: DayCalendar(schedule: .standard), rounding: .default,
               timeCalendar: bratislava, now: t(now), knownFrom: knownFrom.map(d))
    }

    @Test func unsentIsNotNeedsYou() {
        // Thu 1 – Tue 6 Oct: every workday tracked, all unsent.
        let days = ["2026-10-01", "2026-10-02", "2026-10-05", "2026-10-06"]
        let l = ledger(days.map { entry("\($0) 09:00", "\($0) 17:00", issue: "1", project: p.id) })
        let n = l.needsYou(in: DateRange(d("2026-10-01"), d("2026-10-06")), lock: LockPolicy(), jiraConnected: true)
        #expect(n.isEmpty)
        let calm = l.notInJira(in: DateRange(d("2026-10-01"), d("2026-10-06")), lock: LockPolicy())
        #expect(calm.worklogs == 4)
        #expect(calm.seconds == 4 * 8 * 3600)
    }

    @Test func blockersAreCountedWithTheirUnit() {
        let failed = WorklogGroup(instanceId: inst, issueId: "2", localDate: d("2026-10-02"), syncState: .error)
        let l = ledger([
            entry("2026-10-01 09:00", "2026-10-01 12:00", project: p.id, desc: "no task"),
            entry("2026-10-01 12:00", "2026-10-01 17:00", project: p.id, desc: "no task either"),
            entry("2026-10-02 09:00", "2026-10-02 17:00", issue: "2", project: p.id),
            // Mon 5 Oct: nothing tracked → an empty workday.
            entry("2026-10-06 09:00", nil, project: p.id, desc: "running, no task yet"),
        ], groups: [failed])
        let n = l.needsYou(in: DateRange(d("2026-10-01"), d("2026-10-06")), lock: LockPolicy(), jiraConnected: true)
        #expect(n.noTask == 2)          // the running entry doesn't count yet
        #expect(n.worklogs == 1)
        #expect(n.emptyDays == [d("2026-10-05")])
        #expect(n.days == [d("2026-10-01"), d("2026-10-02"), d("2026-10-05")])
        #expect(n.count == 4)
        // Without Jira nothing blocks sending.
        #expect(l.needsYou(in: DateRange(d("2026-10-01"), d("2026-10-06")), lock: LockPolicy(), jiraConnected: false).isEmpty)
    }

    /// The Unsent badge (variant B, 2026-10-06): days not in Jira, amber when something needs you.
    @Test func unsentBadgeCountsDaysNotInJira() {
        let week = DateRange(d("2026-10-01"), d("2026-10-06"))
        let sent = WorklogGroup(instanceId: inst, issueId: "1", localDate: d("2026-10-01"), remoteWorklogId: "w1",
                                lastSent: SentSnapshot(startedAt: t("2026-10-01 09:00"), durationSeconds: 8 * 3600, comment: ""),
                                sentRaw: 8 * 3600, syncState: .synced)
        let calm = ledger([
            entry("2026-10-01 09:00", "2026-10-01 17:00", issue: "1", project: p.id),   // in Jira
            entry("2026-10-02 09:00", "2026-10-02 17:00", issue: "1", project: p.id),   // unsent
            entry("2026-10-05 09:00", "2026-10-05 17:00", issue: "2", project: p.id),   // unsent
            entry("2026-10-06 09:00", nil, issue: "1", project: p.id),                  // today: running only
        ], groups: [sent])
        let b = calm.unsentBadge(in: week, lock: LockPolicy(), jiraConnected: true)
        #expect(b.days == [d("2026-10-02"), d("2026-10-05")])
        #expect(b.count == 2 && !b.needsYou && !b.isHidden)
        // Today counts once it has finished, unsent time (the running part alone doesn't).
        let today = ledger([
            entry("2026-10-01 09:00", "2026-10-01 17:00", issue: "1", project: p.id),
            entry("2026-10-02 09:00", "2026-10-02 17:00", issue: "1", project: p.id),
            entry("2026-10-05 09:00", "2026-10-05 17:00", issue: "2", project: p.id),
            entry("2026-10-06 09:00", "2026-10-06 10:00", issue: "1", project: p.id),
            entry("2026-10-06 10:00", nil, issue: "1", project: p.id),
        ], groups: [sent])
        #expect(today.unsentBadge(in: week, lock: LockPolicy(), jiraConnected: true).days.last == d("2026-10-06"))
        // …but not when its finished part is already in Jira and only the running part is new.
        let sentToday = WorklogGroup(instanceId: inst, issueId: "1", localDate: d("2026-10-06"), remoteWorklogId: "w2",
                                     lastSent: SentSnapshot(startedAt: t("2026-10-06 09:00"), durationSeconds: 3600, comment: ""),
                                     sentRaw: 3600, syncState: .synced)
        let running = ledger([
            entry("2026-10-06 09:00", "2026-10-06 10:00", issue: "1", project: p.id),
            entry("2026-10-06 10:00", nil, issue: "1", project: p.id),
        ], groups: [sentToday], knownFrom: "2026-10-06")
        #expect(running.unsentBadge(in: DateRange(d("2026-10-06"), d("2026-10-06")), lock: LockPolicy(), jiraConnected: true).isHidden)
        // A blocker turns it amber; the number stays days.
        let blocked = ledger([
            entry("2026-10-01 09:00", "2026-10-01 17:00", issue: "1", project: p.id),
            entry("2026-10-02 09:00", "2026-10-02 17:00", project: p.id, desc: "no task"),
            entry("2026-10-05 09:00", "2026-10-05 17:00", issue: "2", project: p.id),
            entry("2026-10-06 09:00", nil, project: p.id, desc: "running, no task yet"),
        ], groups: [sent])
        let a = blocked.unsentBadge(in: week, lock: LockPolicy(), jiraConnected: true)
        #expect(a.days == [d("2026-10-02"), d("2026-10-05")])
        #expect(a.needsYou)
        // Everything in Jira → hidden; without Jira → hidden.
        let done = ledger([entry("2026-10-01 09:00", "2026-10-01 17:00", issue: "1", project: p.id)], groups: [sent], knownFrom: "2026-10-01")
        #expect(done.unsentBadge(in: DateRange(d("2026-10-01"), d("2026-10-01")), lock: LockPolicy(), jiraConnected: true).isHidden)
        #expect(calm.unsentBadge(in: week, lock: LockPolicy(), jiraConnected: false).isHidden)
        // An empty workday needs you and counts as a day not in Jira (the amber badge never says 0).
        let empty = ledger([entry("2026-10-01 09:00", "2026-10-01 17:00", issue: "1", project: p.id)], groups: [sent])
        let e = empty.unsentBadge(in: DateRange(d("2026-10-01"), d("2026-10-02")), lock: LockPolicy(), jiraConnected: true)
        #expect(e.days == [d("2026-10-02")] && e.needsYou)
    }

    @Test func runningTimeIsLeftOutOfTheSendableValue() {
        let l = ledger([
            entry("2026-10-06 09:00", "2026-10-06 10:38", issue: "1", project: p.id),
            entry("2026-10-06 17:00", nil, issue: "1", project: p.id),
        ])
        let line = l.lines(on: d("2026-10-06"))[0]
        #expect(line.containsRunning)
        let s = l.sendablePart(of: line)
        #expect(s?.raw == 98 * 60)
        #expect(s?.value == 100 * 60)  // 1h 40m — what Review sends
        #expect(s?.excludesRunning == true)
        let onlyRunning = ledger([entry("2026-10-06 17:00", nil, issue: "1", project: p.id)])
        #expect(onlyRunning.sendablePart(of: onlyRunning.lines(on: d("2026-10-06"))[0]) == nil)
    }
}

@Suite struct BalanceStartTests {
    @Test func effectiveStartIsTheFirstData() {
        let today = d("2026-10-06")
        let start = BalanceStart.dataStart(opening: nil, historyStarts: [d("2026-08-01")], firstEntry: d("2026-08-03"), today: today)
        #expect(start == d("2026-08-01"))
        #expect(BalanceStart.effective(configured: nil, dataStart: start, today: today) == d("2026-08-01"))
        #expect(BalanceStart.differs(configured: nil, dataStart: start, today: today))
        #expect(!BalanceStart.differs(configured: d("2026-09-01"), dataStart: start, today: today))
        #expect(BalanceStart.importStartsLate(historyStart: d("2026-08-01"), configured: nil, today: today))
        #expect(!BalanceStart.importStartsLate(historyStart: d("2026-01-01"), configured: nil, today: today))
    }

    @Test func openingBalanceIsAsOfTheImportStart() {
        let today = d("2026-10-06")
        #expect(BalanceStart.openingDate(historyStart: d("2026-09-01"), today: today) == d("2026-09-01"))
        #expect(BalanceStart.openingDate(historyStart: nil, today: today) == today)
        // The carried-over hours count once, from the import start on.
        let o = OpeningBalance(date: d("2026-09-01"), seconds: 6 * 3600)
        let l = Ledger(entries: [], groups: [], projects: [], calendar: DayCalendar(schedule: WorkSchedule(periods: [WorkSchedulePeriod(effectiveFrom: d("2000-01-01"), workdays: [])])),
                       rounding: .default, timeCalendar: bratislava, now: t("2026-10-06 12:00"))
        let start = BalanceStart.effective(configured: nil, dataStart: o.date, today: today)
        #expect(l.cumulativeBalance(since: start, opening: o) == 6 * 3600)
    }

    @Test func monthsWithoutDataAreNotZeroPercent() {
        let p = Project(name: "P", color: "blue", billable: true)
        let l = Ledger(entries: [entry("2026-10-01 08:00", "2026-10-01 16:00", issue: "1", project: p.id)], groups: [], projects: [p],
                       calendar: DayCalendar(schedule: .standard), rounding: .default, timeCalendar: bratislava, now: t("2026-10-01 18:00"))
        #expect(l.monthUtilization(DateRange.month(of: d("2026-09-01")), since: nil, through: d("2026-10-01")) == nil)
        #expect(l.monthUtilization(DateRange.month(of: d("2026-10-01")), since: nil, through: d("2026-10-01")) == 1.0)
        // Year to date: September (no data) doesn't drag October's 100 % down.
        #expect(l.utilizationOfMonthsWithData(DateRange(d("2026-01-01"), d("2026-10-01")), through: d("2026-10-01")) == 1.0)
    }
}

@Suite struct NudgeTests {
    @Test func importDefault() {
        let lock = LockPolicy(graceDays: 5)
        #expect(Nudges.importStart(today: d("2026-10-01"), lock: lock) == d("2026-09-01"))
        #expect(Nudges.importStart(today: d("2026-10-05"), lock: lock) == d("2026-09-01"))
        #expect(Nudges.importStart(today: d("2026-10-06"), lock: lock) == d("2026-10-01"))
    }

    /// Day 1 after onboarding: one evening nudge, at the end of working hours, only while today is unsent.
    @Test func firstDayEveningNudge() {
        let day = d("2026-10-06"), end = 16 * 60 + 30
        #expect(Nudges.firstDay(nudgeDay: day, today: day, minutes: 16 * 60, workdayEnd: end, todayUnsent: true) == .wait)
        #expect(Nudges.firstDay(nudgeDay: day, today: day, minutes: end, workdayEnd: end, todayUnsent: true) == .show)
        #expect(Nudges.firstDay(nudgeDay: day, today: day, minutes: end + 60, workdayEnd: end, todayUnsent: false) == .wait)
        #expect(Nudges.firstDay(nudgeDay: day, today: d("2026-10-05"), minutes: end + 60, workdayEnd: end, todayUnsent: true) == .wait)
        #expect(Nudges.firstDay(nudgeDay: day, today: d("2026-10-07"), minutes: end + 60, workdayEnd: end, todayUnsent: true) == .drop)
    }
}

@Suite struct AwayTests {
    @Test func wakingAfterMidnightSplitsTheTimer() {
        // Timer started Mon 22:00, the Mac slept 23:10 → Tue 08:30. The clock reading from before the wake is Monday.
        let before = t("2026-10-05 23:10"), after = t("2026-10-06 08:30")
        #expect(AwayOps.dayChanged(from: before, to: after, calendar: bratislava))
        #expect(!AwayOps.dayChanged(from: after, to: after, calendar: bratislava))   // the bug: comparing after advancing
        let r = entry("2026-10-05 22:00", nil, issue: "1")
        let parts = AwayOps.splitRunning(r, today: d("2026-10-06"), calendar: bratislava)
        #expect(parts.count == 2)
        #expect(parts[0].id == r.id && parts[0].end == t("2026-10-06 00:00"))
        #expect(parts[1].start == t("2026-10-06 00:00") && parts[1].isRunning)
        #expect(AwayOps.splitRunning(r, today: d("2026-10-05"), calendar: bratislava).isEmpty)
        // Two midnights (a long weekend asleep).
        #expect(AwayOps.splitRunning(r, today: d("2026-10-07"), calendar: bratislava).count == 3)
    }

    @Test func stopAtWhenYouLeftDoesNotRestart() {
        let r = entry("2026-10-06 09:00", nil, issue: "1")
        let ch = AwayOps.stop(at: t("2026-10-06 17:30"), running: r, entries: [r])
        #expect(ch.inserted.isEmpty && ch.deleted.isEmpty)
        #expect(ch.updated.count == 1 && ch.updated[0].end == t("2026-10-06 17:30"))
    }

    @Test func stopAtAcrossAMidnightSplit() {
        // Left Mon 17:30, the timer ran on and was split at midnight: Monday's part ends at 17:30, Tuesday's goes.
        let mon = entry("2026-10-05 09:00", "2026-10-06 00:00", issue: "1")
        var tue = entry("2026-10-06 00:00", nil, issue: "1")
        tue.id = UUID()
        let other = entry("2026-10-05 08:00", "2026-10-05 09:00", issue: "2")
        let ch = AwayOps.stop(at: t("2026-10-05 17:30"), running: tue, entries: [other, mon, tue])
        #expect(ch.deleted.map(\.id) == [tue.id])
        #expect(ch.updated.map(\.id) == [mon.id])
        #expect(ch.updated[0].end == t("2026-10-05 17:30"))
    }
}
