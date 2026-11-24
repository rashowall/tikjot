import Foundation

/// One Jira worklog as tikjot sees it (task × day), or a no-task entry.
public struct WorklogLine: Identifiable, Hashable, Sendable {
    public init(key: Key, date: LocalDate, entries: [TimeEntry], issue: IssueRef?, projectId: UUID?, group: WorklogGroup?, raw: Seconds, value: Seconds, started: Date, descriptions: [String], containsRunning: Bool) {
        self.key = key; self.date = date; self.entries = entries; self.issue = issue; self.projectId = projectId; self.group = group
        self.raw = raw; self.value = value; self.started = started; self.descriptions = descriptions; self.containsRunning = containsRunning
    }

    public enum Key: Hashable, Sendable {
        /// All local entries of an issue on a day (one app worklog).
        case app(IssueRef, LocalDate)
        /// One imported worklog (one entry).
        case imported(UUID)
        /// A single entry without an issue.
        case noIssue(UUID)
    }

    public var id: Key { key }
    public let key: Key
    public let date: LocalDate
    public let entries: [TimeEntry]
    public let issue: IssueRef?
    public let projectId: UUID?
    public let group: WorklogGroup?
    /// Sum of raw entry durations.
    public let raw: Seconds
    /// The value that is / will be in Jira (§2.3: the numbers in the app equal the numbers in Jira).
    public let value: Seconds
    /// Start of the earliest entry (§9.4).
    public let started: Date
    /// Unique non-empty descriptions in order of first occurrence (§9.3).
    public let descriptions: [String]
    public let containsRunning: Bool

    public var isNoIssue: Bool { issue == nil }

    /// Comment as it will be sent, in plain text (override wins).
    public var comment: String {
        if let o = group?.commentOverride { return o }
        return WorklogLine.plainComment(descriptions)
    }

    public static func plainComment(_ descriptions: [String]) -> String { DescriptionLines.comment(descriptions) }

    /// Descriptions joined on one line for lists ("Sprint review; Notes"); each line of a multi-line one counts.
    public var commentLine: String {
        if let o = group?.commentOverride { return o.replacingOccurrences(of: "\n", with: "; ") }
        return descriptions.flatMap(DescriptionLines.lines).joined(separator: "; ")
    }

    public static func uniqueDescriptions(_ entries: [TimeEntry]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for e in entries.sorted(by: { $0.start < $1.start }) {
            let d = e.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !d.isEmpty, !seen.contains(d) else { continue }
            seen.insert(d)
            out.append(d)
        }
        return out
    }
}

/// Everything needed to compute days: entries, groups, projects, calendar and rounding.
/// Pure — build one from the store and ask it questions.
public struct Ledger: Sendable {
    public let entries: [TimeEntry]
    public let groups: [UUID: WorklogGroup]
    public let projects: [UUID: Project]
    public let calendar: DayCalendar
    public let rounding: RoundingRule
    public let timeCalendar: Calendar
    public let now: Date
    /// First day tikjot knows anything about (history start / first entry). Days before it are never "missed".
    public let knownFrom: LocalDate?

    private let entriesByDay: [LocalDate: [TimeEntry]]
    private let groupsByKey: [WorklogGroupKey: WorklogGroup]
    private let groupsByDay: [LocalDate: [WorklogGroup]]

    public init(entries: [TimeEntry], groups: [WorklogGroup], projects: [Project], calendar: DayCalendar,
                rounding: RoundingRule, timeCalendar: Calendar, now: Date, knownFrom: LocalDate? = nil) {
        self.knownFrom = knownFrom
        let live = entries.filter { $0.deletedAt == nil }
        self.entries = live
        self.groups = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.projects = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.calendar = calendar
        self.rounding = rounding
        self.timeCalendar = timeCalendar
        self.now = now
        var byDay: [LocalDate: [TimeEntry]] = [:]
        for e in live {
            // An imported worklog stays whole on the day it started, as Jira counts it: split, its first day looked
            // shorter than Jira and asked to send the parts back as two worklogs (beta 2026-10-21).
            if e.source == .imported && e.end != nil {
                byDay[LocalDate(e.start, calendar: timeCalendar), default: []].append(e)
                continue
            }
            for part in EntryOps.splitAtMidnight(e, now: now, calendar: timeCalendar) {
                byDay[LocalDate(part.start, calendar: timeCalendar), default: []].append(part)
            }
        }
        self.entriesByDay = byDay.mapValues { $0.sorted { $0.start < $1.start } }
        let liveGroups = groups.filter { $0.deletedAt == nil }
        self.groupsByKey = Dictionary(liveGroups.filter { $0.kind == .app }.map {
            (WorklogGroupKey(issue: $0.issueRef, date: $0.localDate), $0)
        }, uniquingKeysWith: { a, _ in a })
        self.groupsByDay = Dictionary(grouping: liveGroups, by: \.localDate)
    }

    public var today: LocalDate { LocalDate(now, calendar: timeCalendar) }

    /// Entries of a day (running entry clipped to now, midnight-crossing entries split — imported worklogs stay whole on
    /// their first day), sorted by start.
    public func entries(on d: LocalDate) -> [TimeEntry] { entriesByDay[d] ?? [] }

    /// Work entries only (breaks excluded).
    public func workEntries(on d: LocalDate) -> [TimeEntry] { entries(on: d).filter { $0.kind == .work } }

    public func groups(on d: LocalDate) -> [WorklogGroup] { groupsByDay[d] ?? [] }

    public func appGroup(_ issue: IssueRef, _ d: LocalDate) -> WorklogGroup? {
        groupsByKey[WorklogGroupKey(issue: issue, date: d)]
    }

    // MARK: Lines

    public func lines(on d: LocalDate) -> [WorklogLine] {
        var out: [WorklogLine] = []
        let work = workEntries(on: d)
        var appBuckets: [IssueRef: [TimeEntry]] = [:]
        for e in work {
            if let ref = e.issueRef {
                if e.source == .imported {
                    out.append(importedLine(e, d))
                } else {
                    appBuckets[ref, default: []].append(e)
                }
            } else {
                out.append(line(.noIssue(e.id), d, [e], issue: nil, group: nil, value: e.duration(now: now)))
            }
        }
        for (ref, es) in appBuckets {
            let g = appGroup(ref, d)
            let raw = es.reduce(0) { $0 + $1.duration(now: now) }
            let value: Seconds
            if let g, let sent = g.lastSent, g.sentRaw == raw {
                value = sent.durationSeconds
            } else {
                value = rounding.apply(raw)
            }
            out.append(line(.app(ref, d), d, es, issue: ref, group: g, value: value))
        }
        // Groups whose entries were all deleted but still exist in Jira (pending delete) — value 0 here.
        return out.sorted { $0.started < $1.started }
    }

    private func importedLine(_ e: TimeEntry, _ d: LocalDate) -> WorklogLine {
        let g = e.worklogGroupId.flatMap { groups[$0] }
        // Imported worklogs are never re-rounded (§8.1).
        let raw = e.duration(now: now)
        let value: Seconds
        if let g, let sent = g.lastSent, g.sentRaw == raw {
            value = sent.durationSeconds
        } else {
            value = RoundingRule.off.apply(raw)
        }
        return line(.imported(e.id), d, [e], issue: e.issueRef, group: g, value: value)
    }

    private func line(_ key: WorklogLine.Key, _ d: LocalDate, _ es: [TimeEntry], issue: IssueRef?, group: WorklogGroup?, value: Seconds) -> WorklogLine {
        let sorted = es.sorted { $0.start < $1.start }
        return WorklogLine(
            key: key, date: d, entries: sorted, issue: issue,
            projectId: sorted.first?.projectId, group: group,
            raw: sorted.reduce(0) { $0 + $1.duration(now: now) }, value: value,
            started: sorted.first?.start ?? d.start(in: timeCalendar),
            descriptions: WorklogLine.uniqueDescriptions(sorted),
            containsRunning: sorted.contains(where: \.isRunning))
    }

    // MARK: Day numbers (§8.3)

    private func counts(_ line: WorklogLine) -> Bool {
        guard let pid = line.projectId, let p = projects[pid] else { return true }
        return !p.excludeFromWorked
    }

    private func isBillable(_ line: WorklogLine) -> Bool {
        guard let pid = line.projectId, let p = projects[pid] else { return false }
        return p.billable && !p.excludeFromWorked
    }

    /// Σ rounded app groups + Σ imported + Σ raw no-issue, excluding `excludeFromWorked` projects.
    public func worked(_ d: LocalDate) -> Seconds {
        lines(on: d).filter(counts).reduce(0) { $0 + $1.value }
    }

    public func worked(_ range: DateRange) -> Seconds { range.reduce(0) { $0 + worked($1) } }

    public func billableWorked(_ d: LocalDate) -> Seconds {
        lines(on: d).filter(isBillable).reduce(0) { $0 + $1.value }
    }

    public func billableWorked(_ range: DateRange) -> Seconds { range.reduce(0) { $0 + billableWorked($1) } }

    /// Raw tracked time (no rounding) — shown in detail ("1h 52m → 1h 50m").
    public func raw(_ d: LocalDate) -> Seconds {
        workEntries(on: d).reduce(0) { $0 + $1.duration(now: now) }
    }

    /// What is currently stored in Jira for this day.
    public func inJira(_ d: LocalDate) -> Seconds {
        groups(on: d).reduce(0) { sum, g in
            guard g.remoteWorklogId != nil, g.syncState != .remoteDeleted, let s = g.lastSent else { return sum }
            return sum + s.durationSeconds
        }
    }

    public func inJira(_ range: DateRange) -> Seconds { range.reduce(0) { $0 + inJira($1) } }

    public func noIssueSeconds(_ d: LocalDate) -> Seconds {
        lines(on: d).filter(\.isNoIssue).reduce(0) { $0 + $1.value }
    }

    public func fund(_ d: LocalDate) -> Seconds { calendar.fund(d) }

    public func fund(_ range: DateRange) -> Seconds { calendar.fund(range) }

    /// Today's fund filled linearly through working hours (popover footer, §11.1 "Footer balance").
    public func liveFund(_ d: LocalDate) -> Seconds { live(fund(d), on: d) }

    /// The full fund (no absences taken off, see `DayCalendar.fullFund`).
    public func fullFund(_ d: LocalDate) -> Seconds { calendar.fullFund(d) }

    public func fullFund(_ range: DateRange) -> Seconds { calendar.fullFund(range) }

    /// A day's `seconds` as far as it has gone: past days whole, future days 0, today linearly through working hours.
    private func live(_ seconds: Seconds, on d: LocalDate) -> Seconds {
        guard d == today else { return d < today ? seconds : 0 }
        let p = calendar.schedule.period(on: d)
        let start = d.at(minutes: p.workdayStart, in: timeCalendar)
        let end = d.at(minutes: p.workdayEnd, in: timeCalendar)
        guard end > start else { return seconds }
        let frac = min(1, max(0, now.timeIntervalSince(start) / end.timeIntervalSince(start)))
        return Int((Double(seconds) * frac).rounded())
    }

    // MARK: Balance (§8.4) & utilization (§8.5)

    /// Balance of `range` up to and including `through` (default: yesterday). `since`: the first day tikjot knows
    /// (days before it have no data, so their fund isn't a deficit).
    public func balance(_ range: DateRange, through: LocalDate? = nil, since: LocalDate? = nil) -> Seconds {
        let first = max(range.start, since ?? range.start)
        let last = min(range.end, through ?? today.adding(days: -1))
        guard last >= first else { return 0 }
        let r = DateRange(first, last)
        return worked(r) - fund(r)
    }

    /// A day's ± in the balance. Past days: worked − fund. Today: overtime counts at once, a shortfall only once
    /// the working day is over (its end in the schedule) — no "−6h" in the morning. The pace during the day is
    /// `worked − liveFund` ("26m behind").
    public func dayBalance(_ d: LocalDate) -> Seconds {
        if d > today { return 0 }
        let b = worked(d) - fund(d)
        guard d == today, b < 0 else { return b }
        let p = calendar.schedule.period(on: d)
        return now >= d.at(minutes: p.workdayEnd, in: timeCalendar) ? b : 0
    }

    /// Balance including today (see `dayBalance`) — the same number in the sidebar, toolbars, Month and widget.
    public func liveBalance(_ range: DateRange, since: LocalDate? = nil) -> Seconds {
        var b = balance(range, since: since)
        if range.contains(today), today >= (since ?? today) { b += dayBalance(today) }
        return b
    }

    public func cumulativeBalance(since start: LocalDate, opening: OpeningBalance?, through: LocalDate? = nil) -> Seconds {
        let last = through ?? today.adding(days: -1)
        var b = last >= start ? balance(DateRange(start, last), through: last) : 0
        if let o = opening, o.date >= start, o.date <= last { b += o.seconds }
        return b
    }

    /// Utilization (§8.5, owner 2026-10-07): billable worked ÷ full fund — workdays' hours minus public holidays and
    /// company days off only. Absences (vacation, doctor, sick …) stay in the fund, so they lower it; overtime takes it
    /// above 100 %. Counts up to `through` (default: the range's end) and never past today; today counts its billable
    /// so far against its full fund as far as the working day has gone (as `liveFund`). Nil without any fund.
    public func utilization(_ range: DateRange, through: LocalDate? = nil) -> Double? {
        guard let r = utilizationWindow(range, through: through) else { return nil }
        let f = utilizationFund(r)
        guard f > 0 else { return nil }
        return Double(billableWorked(r)) / Double(f)
    }

    /// The days utilization counts in `range`: through `through` and today at the latest.
    func utilizationWindow(_ range: DateRange, through: LocalDate? = nil) -> DateRange? {
        let last = min(range.end, through ?? range.end, today)
        return last >= range.start ? DateRange(range.start, last) : nil
    }

    /// Utilization's denominator: the full fund of the days, today's as far as the working day has gone.
    public func utilizationFund(_ range: DateRange) -> Seconds {
        range.reduce(0) { $0 + live(fullFund($1), on: $1) }
    }

    /// "Remaining this month": hours needed until month end and average per remaining workday (§8.4).
    public func remaining(in month: DateRange) -> (needed: Seconds, workdays: Int, perDay: Seconds) {
        let fundAll = fund(month)
        let workedSoFar = worked(DateRange(month.start, min(month.end, today)))
        let needed = max(0, fundAll - workedSoFar)
        let from = today.adding(days: 1)
        let days = from <= month.end ? calendar.workdays(in: DateRange(from, month.end)).count : 0
        return (needed, days, days > 0 ? needed / days : needed)
    }
}

struct WorklogGroupKey: Hashable, Sendable {
    let issue: IssueRef
    let date: LocalDate
}
