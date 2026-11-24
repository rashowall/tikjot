import Foundation
import TikjotDomain
import TikjotPersistence

extension WidgetSnapshot {
    @MainActor
    static func make(_ m: AppModel) -> WidgetSnapshot {
        let l = m.ledger
        let today = m.today
        func run(_ e: TimeEntry) -> Running {
            let i = m.issue(for: e)
            return Running(description: e.description.descriptionFirstLine, key: i?.key, taskName: i?.summary ?? m.project(e.projectId)?.name ?? String(localized: "No task"),
                           color: m.project(e.projectId)?.color ?? "slate", start: e.start)
        }
        let rows: [Row] = l.workEntries(on: today).suffix(6).map { e in
            let r = run(e)
            return Row(description: e.description.descriptionFirstLine, key: r.key, taskName: r.taskName, color: r.color, start: e.start, end: e.end, seconds: e.duration(now: m.now), isAbsence: false)
        }
        let cal = m.dayCalendar
        var dayOff: String?
        var dayOffText: String?
        if let h = cal.holidays[today] { dayOff = "holiday"; dayOffText = h.name }
        else if let a = m.absences(on: today).first, let t = m.absenceType(a.typeId) {
            if a.unit == .hours {
                if let sm = a.startMinutes {
                    let start = today.at(minutes: sm, in: m.timeCalendar)
                    let end = start.addingTimeInterval(TimeInterval(a.amountSeconds))
                    if m.now >= start && m.now < end { dayOff = "doctor"; dayOffText = "\(Fmt.time(start))–now · back at \(Fmt.time(end))" }
                }
            } else if a.unit == .day {
                dayOff = t.builtin?.rawValue ?? "vacation"
                dayOffText = t.name
            }
        } else if cal.dayType(today) == .weekend { dayOff = "weekend" }
        let status = l.dayStatus(today, lock: m.lock, jiraConnected: m.jiraConnected)
        return WidgetSnapshot(
            generatedAt: Clock.now, dayTitle: Fmt.weekday(today), worked: l.worked(today), fund: l.fund(today),
            allInJira: status == .allInJira && l.worked(today) > 0,
            running: m.runningEntry.map(run),
            lastTask: m.data.entries.last(where: { $0.end != nil && $0.kind == .work }).map(run),
            rows: rows, unsentDays: m.unsentDays().filter { $0 < today }.count,
            dayOff: dayOff, dayOffText: dayOffText, signedOut: !m.signedOutInstances.isEmpty,
            yesterdayWorked: l.worked(today.adding(days: -1)),
            balanceText: DurationFormat.signed(l.liveBalance(m.balanceRange, since: m.dataStart)))
    }
}

extension WidgetSnapshot {
    /// What the widget shows, minus what only moves with the clock (generation time, the running entry's elapsed
    /// seconds, the live balance) — equal signatures mean a reload would draw the same widget.
    func reloadSignature(now: Date) -> Data {
        var s = self
        s.generatedAt = .distantPast
        if let r = running { s.worked -= max(0, Int(now.timeIntervalSince(r.start))) }
        s.rows = rows.map { var x = $0; if x.end == nil { x.seconds = 0 }; return x }
        s.balanceText = ""
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return (try? e.encode(s)) ?? Data()
    }
}

