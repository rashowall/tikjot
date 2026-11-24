import Foundation

/// Calendar facts needed by the fund calculation: holidays, custom days, absences and the contract.
public struct DayCalendar: Sendable {
    public var schedule: WorkSchedule
    public var holidays: [LocalDate: Holiday]
    public var customDays: [LocalDate: CustomDay]
    public var absences: [LocalDate: [Absence]]

    public init(schedule: WorkSchedule, holidays: [Holiday] = [], customDays: [CustomDay] = [], absences: [Absence] = []) {
        self.schedule = schedule
        self.holidays = Dictionary(holidays.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        self.customDays = Dictionary(customDays.map { ($0.date, $0) }, uniquingKeysWith: { _, b in b })
        self.absences = Dictionary(grouping: absences.filter { $0.deletedAt == nil }, by: \.date)
    }

    public enum DayType: String, Sendable, Codable {
        case workday, weekend, holiday, custom
    }

    public func dayType(_ d: LocalDate) -> DayType {
        if holidays[d] != nil { return .holiday }
        if customDays[d] != nil { return .custom }
        return schedule.period(on: d).workdays.contains(d.isoWeekday) ? .workday : .weekend
    }

    /// Fund before absences (§8.2 `base`).
    public func baseFund(_ d: LocalDate) -> Seconds {
        switch dayType(d) {
        case .holiday, .weekend: return 0
        case .custom:
            let h = customDays[d]?.hours ?? 0
            return h.isFinite ? Int((Swift.min(Swift.max(h, 0), 24) * 3600).rounded()) : 0
        case .workday: return schedule.period(on: d).dailySeconds
        }
    }

    public func absenceSeconds(_ d: LocalDate) -> Seconds {
        let base = baseFund(d)
        let daily = schedule.period(on: d).dailySeconds
        return (absences[d] ?? []).reduce(0) { sum, a in
            switch a.unit {
            case .day: return sum + base
            case .halfDay: return sum + daily / 2
            case .hours: return sum + a.amountSeconds
            }
        }
    }

    /// §8.2: fund = max(0, base − absent).
    public func fund(_ d: LocalDate) -> Seconds {
        max(0, baseFund(d) - absenceSeconds(d))
    }

    public func fund(_ range: DateRange) -> Seconds {
        range.reduce(0) { $0 + fund($1) }
    }

    /// The full fund (§8.5, utilization's denominator): scheduled hours minus public holidays and company days off
    /// only — absences don't reduce it (a vacation day lowers utilization). Equals `baseFund`.
    public func fullFund(_ d: LocalDate) -> Seconds { baseFund(d) }

    public func fullFund(_ range: DateRange) -> Seconds {
        range.reduce(0) { $0 + fullFund($1) }
    }

    /// Whole day off: holiday, weekend, or a full-day absence.
    public func isDayOff(_ d: LocalDate) -> Bool {
        let t = dayType(d)
        if t == .holiday || t == .weekend { return true }
        return (absences[d] ?? []).contains { $0.unit == .day }
    }

    public func isWorkday(_ d: LocalDate) -> Bool {
        let t = dayType(d)
        return t == .workday || (t == .custom && baseFund(d) > 0)
    }

    /// Working days in a range (for "date ranges count working days only", §11.8).
    public func workdays(in range: DateRange) -> [LocalDate] {
        range.filter { isWorkday($0) }
    }
}
