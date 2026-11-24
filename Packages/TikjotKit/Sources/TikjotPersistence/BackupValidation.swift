import Foundation
import TikjotDomain

extension DataSnapshot {
    /// A restored backup must not hold values that break the app later (a crash at every launch): dates outside
    /// `LocalDate.validYears`, entries of 48 h or more (tracked here; a Jira worklog may be longer), durations that overflow when summed. Such a backup is
    /// refused as a whole (`backupOutOfRange`); settings are clamped to the ranges Settings offers.
    public func validated() throws -> DataSnapshot {
        let utc = TimeZone(identifier: "UTC")
        let cal = Calendar(identifier: .gregorian)
        let earliest = cal.date(from: DateComponents(timeZone: utc, year: LocalDate.validYears.lowerBound, month: 1, day: 2)) ?? .distantPast
        let latest = cal.date(from: DateComponents(timeZone: utc, year: LocalDate.validYears.upperBound, month: 12, day: 30)) ?? .distantFuture
        func date(_ d: Date?) -> Bool { d.map { $0.timeIntervalSinceReferenceDate.isFinite && $0 >= earliest && $0 <= latest } ?? true }
        func day(_ d: LocalDate?) -> Bool { d?.isValid ?? true }
        /// Durations: at most ~30 years of seconds, so sums can't overflow.
        func secs(_ s: Seconds?) -> Bool { s.map { abs($0) <= 1_000_000_000 } ?? true }
        func hours(_ h: Double) -> Bool { h.isFinite && (0...24).contains(h) }
        func minuteOfDay(_ m: Int?) -> Bool { m.map { (0...1440).contains($0) } ?? true }
        func sent(_ s: SentSnapshot?) -> Bool { s.map { date($0.startedAt) && secs($0.durationSeconds) } ?? true }

        let ok = instances.allSatisfy { date($0.lastSyncAt) && date($0.syncCursor) && day($0.historyStartDate) && day($0.successionDate) && day($0.tokenExpires) }
            && entries.allSatisfy { e in
                date(e.start) && date(e.end) && (e.end.map { abs($0.timeIntervalSince(e.start)) < (e.source == .imported ? 1e9 : 48 * 3600) } ?? true)
            }
            && groups.allSatisfy { g in
                day(g.localDate) && sent(g.lastSent) && sent(g.remoteVersion) && secs(g.sentRaw) && secs(g.changedInJiraWas) && date(g.remoteUpdated)
            }
            && issues.allSatisfy { secs($0.originalEstimateSeconds) && secs($0.timeSpentSeconds) && date($0.updated) }
            && schedule.allSatisfy { p in
                day(p.effectiveFrom) && hours(p.dailyHours) && minuteOfDay(p.workdayStart) && minuteOfDay(p.workdayEnd)
                    && p.workdays.allSatisfy { (1...7).contains($0) }
            }
            && customDays.allSatisfy { day($0.date) && hours($0.hours) }
            && absences.allSatisfy { day($0.date) && (0...86_400).contains($0.amountSeconds) && minuteOfDay($0.startMinutes) }
            && day(settings.cumulativeStart) && day(settings.openingBalance?.date)
        guard ok else { throw PersistenceError.backupOutOfRange }
        var out = self
        out.settings = settings.clamped()
        return out
    }
}
