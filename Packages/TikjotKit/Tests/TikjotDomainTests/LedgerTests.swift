import Foundation
import Testing
@testable import TikjotDomain

@Suite struct LedgerTests {
    let billable = Project(name: "Payments", color: "tangerine", billable: true)
    let internalP = Project(name: "Internal", color: "slate", billable: false)
    let vacationP = Project(name: "Vacation task", color: "blue", billable: false, excludeFromWorked: true)

    func ledger(_ entries: [TimeEntry], groups: [WorklogGroup] = [], now: String = "2026-10-02 18:00", absences: [Absence] = []) -> Ledger {
        Ledger(entries: entries, groups: groups, projects: [billable, internalP, vacationP],
               calendar: DayCalendar(schedule: .standard, absences: absences), rounding: .default,
               timeCalendar: bratislava, now: t(now))
    }

    @Test func roundsDailyTotalPerIssueNotPerEntry() {
        let l = ledger([
            entry("2026-10-01 09:00", "2026-10-01 09:52", issue: "1", project: billable.id, desc: "A"),
            entry("2026-10-01 10:00", "2026-10-01 11:00", issue: "1", project: billable.id, desc: "B"),
            entry("2026-10-01 11:00", "2026-10-01 11:07", project: internalP.id, desc: "no task"),
        ])
        let lines = l.lines(on: d("2026-10-01"))
        #expect(lines.count == 2)
        let app = lines.first { !$0.isNoIssue }!
        #expect(app.raw == 112 * 60)
        #expect(app.value == 110 * 60)
        #expect(app.descriptions == ["A", "B"])
        #expect(app.comment == "• A\n• B")
        // no-issue work is never rounded
        #expect(l.worked(d("2026-10-01")) == 110 * 60 + 7 * 60)
        #expect(l.billableWorked(d("2026-10-01")) == 110 * 60)
    }

    @Test func syncedGroupKeepsJiraValue() {
        let ref = IssueRef(instanceId: inst, issueId: "1")
        let g = WorklogGroup(instanceId: inst, issueId: "1", localDate: d("2026-10-01"), remoteWorklogId: "w1",
                             lastSent: SentSnapshot(startedAt: t("2026-10-01 09:00"), durationSeconds: 3600, comment: ""),
                             sentRaw: 58 * 60, syncState: .synced)
        _ = ref
        let l = ledger([entry("2026-10-01 09:00", "2026-10-01 09:58", issue: "1", project: billable.id)], groups: [g])
        #expect(l.worked(d("2026-10-01")) == 3600)
        #expect(l.inJira(d("2026-10-01")) == 3600)
        #expect(l.state(of: l.lines(on: d("2026-10-01"))[0], lock: LockPolicy()) == .synced)
        // a local edit → re-rounded and modified
        let l2 = ledger([entry("2026-10-01 09:00", "2026-10-01 10:12", issue: "1", project: billable.id)], groups: [g])
        #expect(l2.worked(d("2026-10-01")) == 70 * 60)
        #expect(l2.state(of: l2.lines(on: d("2026-10-01"))[0], lock: LockPolicy()) == .modified)
    }

    @Test func importedWorklogPastMidnightStaysWholeOnItsFirstDay() {
        // Jira: 1h from Thu 23:30. Split, Thursday showed 30m against Jira's 1h and asked to send it back as two.
        let g = WorklogGroup(instanceId: inst, issueId: "1", localDate: d("2026-10-01"), kind: .imported, remoteWorklogId: "w1",
                             lastSent: SentSnapshot(startedAt: t("2026-10-01 23:30"), durationSeconds: 3600, comment: ""),
                             sentRaw: 3600, syncState: .synced)
        var e = entry("2026-10-01 23:30", "2026-10-02 00:30", issue: "1", project: billable.id, source: .imported)
        e.worklogGroupId = g.id
        let l = ledger([e], groups: [g])
        #expect(l.entries(on: d("2026-10-01")).map(\.end) == [t("2026-10-02 00:30")])
        #expect(l.entries(on: d("2026-10-02")).isEmpty)
        #expect(l.worked(d("2026-10-01")) == 3600)
        #expect(l.state(of: l.lines(on: d("2026-10-01"))[0], lock: LockPolicy()) == .synced)
        // Own time past midnight is still split per day.
        let own = ledger([entry("2026-10-01 23:30", "2026-10-02 00:30", issue: "1", project: billable.id)])
        #expect(own.entries(on: d("2026-10-02")).count == 1)
    }

    @Test func excludedProjectIsSentButNotWorked() {
        let l = ledger([entry("2026-10-01 08:00", "2026-10-01 16:00", issue: "9", project: vacationP.id)])
        #expect(l.worked(d("2026-10-01")) == 0)
        #expect(l.lines(on: d("2026-10-01")).count == 1)
    }

    @Test func balanceExcludesToday() {
        let l = ledger([
            entry("2026-10-01 08:00", "2026-10-01 17:00", issue: "1", project: billable.id),
            entry("2026-10-02 08:00", "2026-10-02 10:00", issue: "1", project: billable.id),
        ])
        let oct = DateRange.month(of: d("2026-10-01"))
        #expect(l.balance(oct) == 3600)
        #expect(l.utilization(DateRange(d("2026-10-01"), d("2026-10-01"))) == 9.0 / 8.0)
        // live: today's fund at 18:00 is fully used (after 16:30)
        #expect(l.liveBalance(oct) == 3600 + 2 * 3600 - 8 * 3600)
    }

    @Test func todayCountsOvertimeAtOnceAndShortfallAfterTheDay() {
        let es = [entry("2026-10-01 08:00", "2026-10-01 15:45", issue: "1", project: billable.id),   // −15m
                  entry("2026-10-02 07:50", "2026-10-02 15:55", issue: "1", project: billable.id)]   // today: 8h 05m
        let oct = DateRange.month(of: d("2026-10-01"))
        // 15:52, mid-day: today's +5m counts (not +40m against a half-filled fund).
        let mid = ledger(es, now: "2026-10-02 15:56")
        #expect(mid.dayBalance(d("2026-10-02")) == 5 * 60)
        #expect(mid.liveBalance(oct) == -15 * 60 + 5 * 60)
        // A short day in the afternoon: no minus yet …
        let short = ledger([entry("2026-10-02 08:00", "2026-10-02 12:00", issue: "1", project: billable.id)], now: "2026-10-02 14:00")
        #expect(short.dayBalance(d("2026-10-02")) == 0)
        // … and the shortfall once the working day is over.
        let evening = ledger([entry("2026-10-02 08:00", "2026-10-02 12:00", issue: "1", project: billable.id)], now: "2026-10-02 18:00")
        #expect(evening.dayBalance(d("2026-10-02")) == -4 * 3600)
        // Days before tikjot knew you don't count as missing.
        #expect(mid.liveBalance(oct, since: d("2026-10-02")) == 5 * 60)
    }

    @Test func runningEntryCountsUntilNowAndSplitsAtMidnight() {
        let l = ledger([entry("2026-10-01 23:00", nil, issue: "1", project: billable.id)], now: "2026-10-02 01:30")
        #expect(l.entries(on: d("2026-10-01")).first?.end == t("2026-10-02 00:00"))
        #expect(l.entries(on: d("2026-10-02")).first?.isRunning == true)
        #expect(l.lines(on: d("2026-10-02")).first?.raw == 90 * 60)
    }

    @Test func openingBalanceInCumulative() {
        let l = ledger([])
        let opening = OpeningBalance(date: d("2026-10-01"), seconds: 6 * 3600)
        #expect(l.cumulativeBalance(since: d("2026-10-01"), opening: opening) == 6 * 3600 - 8 * 3600)
    }
}
