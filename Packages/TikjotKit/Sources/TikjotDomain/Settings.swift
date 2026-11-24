import Foundation

/// §8.1
public struct RoundingRule: Hashable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case nearest, up, down }

    /// Unit in minutes; 0 = off.
    public var unitMinutes: Int
    public var mode: Mode

    /// Default for new settings: 5 min, nearest (decided 2026-10-06; was up). Stored settings keep their own rule.
    public init(unitMinutes: Int = 5, mode: Mode = .nearest) {
        self.unitMinutes = unitMinutes
        self.mode = mode
    }

    /// A missing key keeps its default (settings stored before a field existed still decode); keys as synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RoundingRule()
        unitMinutes = try c.decodeIfPresent(Int.self, forKey: .unitMinutes) ?? d.unitMinutes
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? d.mode
    }

    public static let `default` = RoundingRule()
    public static let off = RoundingRule(unitMinutes: 0, mode: .nearest)
    public static let allowedUnits = [0, 1, 5, 10, 15, 30]

    /// Rounds a raw daily total. A positive total never rounds to 0 (minimum one unit).
    /// With rounding off, totals are kept to the whole minute (Jira stores minutes).
    public func apply(_ raw: Seconds) -> Seconds {
        guard raw > 0 else { return 0 }
        let minutes = Self.allowedUnits.contains(unitMinutes) ? unitMinutes : Self.default.unitMinutes
        let unit = (minutes == 0 ? 1 : minutes) * 60
        let mode = minutes == 0 ? .nearest : self.mode
        let q = raw / unit
        let r = raw % unit
        var units: Int
        switch mode {
        case .up: units = r == 0 ? q : q + 1
        case .down: units = q
        case .nearest: units = r * 2 >= unit ? q + 1 : q
        }
        if units == 0 { units = 1 }
        return units * unit
    }
}

public enum BalancePeriod: String, Codable, Sendable, CaseIterable {
    case week, month, quarter
}

/// Global settings (§6.11, §15). Contract data lives in `WorkSchedule`.
public struct AppSettings: Hashable, Codable, Sendable {
    public var rounding: RoundingRule = .default
    public var balancePeriod: BalancePeriod = .month
    /// Cumulative balance start; nil = Jan 1 of the current year.
    public var cumulativeStart: LocalDate?
    public var openingBalance: OpeningBalance?
    public var utilizationTarget: Double = 0.8
    public var graceDays: Int = 5
    /// Not read since the simplicity pass (fixed 3 h in the app) — kept so stored settings decode.
    public var longTimerReminderHours: Double = 3
    public var idleReminderEnabled: Bool = true
    public var idleReminderMinutes: Int = 10
    public var unsentReminderEnabled: Bool = true
    public var longTimerReminderEnabled: Bool = true
    /// Not read since the simplicity pass (fixed 15 min in the app) — kept so stored settings decode.
    public var sleepPromptMinutes: Int = 15
    /// Unused since the simplicity pass (2026-10-06: merged into the morning reminder) — kept so stored settings decode.
    public var monthClosingReminderEnabled: Bool = true
    public var fridayRecapEnabled: Bool = true
    public var menuBarShowsTime: Bool = true
    public var launchAtLogin: Bool = true
    public var autoRefreshMinutes: Int = 30
    public var warnEmptyDescription: Bool = true
    public var snapshotsEnabled: Bool = true
    public var snapshotsKeep: Int = 30
    public var holidayCountry: String = "SK"
    /// "system" | "light" | "dark"
    public var appearance: String = "system"
    /// "system" | "en" | "sk"
    public var language: String = "system"
    public var soundsEnabled: Bool = false
    public var onboardingDone: Bool = false
    public var hotkeyOpen: String = "⌥⌘T"
    public var hotkeyStop: String = "⌥⌘S"

    public init() {}

    /// Every key is optional: settings stored before a field was added keep their other values instead of
    /// resetting to defaults (a stored "up" rounding stays "up"). Unknown keys are ignored. Encoding stays
    /// synthesized, with the same keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        rounding = try v(.rounding, d.rounding)
        balancePeriod = try v(.balancePeriod, d.balancePeriod)
        cumulativeStart = try c.decodeIfPresent(LocalDate.self, forKey: .cumulativeStart)
        openingBalance = try c.decodeIfPresent(OpeningBalance.self, forKey: .openingBalance)
        utilizationTarget = try v(.utilizationTarget, d.utilizationTarget)
        graceDays = try v(.graceDays, d.graceDays)
        longTimerReminderHours = try v(.longTimerReminderHours, d.longTimerReminderHours)
        idleReminderEnabled = try v(.idleReminderEnabled, d.idleReminderEnabled)
        idleReminderMinutes = try v(.idleReminderMinutes, d.idleReminderMinutes)
        unsentReminderEnabled = try v(.unsentReminderEnabled, d.unsentReminderEnabled)
        longTimerReminderEnabled = try v(.longTimerReminderEnabled, d.longTimerReminderEnabled)
        sleepPromptMinutes = try v(.sleepPromptMinutes, d.sleepPromptMinutes)
        monthClosingReminderEnabled = try v(.monthClosingReminderEnabled, d.monthClosingReminderEnabled)
        fridayRecapEnabled = try v(.fridayRecapEnabled, d.fridayRecapEnabled)
        menuBarShowsTime = try v(.menuBarShowsTime, d.menuBarShowsTime)
        launchAtLogin = try v(.launchAtLogin, d.launchAtLogin)
        autoRefreshMinutes = try v(.autoRefreshMinutes, d.autoRefreshMinutes)
        warnEmptyDescription = try v(.warnEmptyDescription, d.warnEmptyDescription)
        snapshotsEnabled = try v(.snapshotsEnabled, d.snapshotsEnabled)
        snapshotsKeep = try v(.snapshotsKeep, d.snapshotsKeep)
        holidayCountry = try v(.holidayCountry, d.holidayCountry)
        appearance = try v(.appearance, d.appearance)
        language = try v(.language, d.language)
        soundsEnabled = try v(.soundsEnabled, d.soundsEnabled)
        onboardingDone = try v(.onboardingDone, d.onboardingDone)
        hotkeyOpen = try v(.hotkeyOpen, d.hotkeyOpen)
        hotkeyStop = try v(.hotkeyStop, d.hotkeyStop)
    }

    /// The same settings with every number inside the range Settings offers (a hand-edited or crafted backup
    /// can't make timers or arithmetic overflow).
    public func clamped() -> AppSettings {
        func clamp<T: Comparable>(_ v: T, _ r: ClosedRange<T>) -> T { Swift.min(Swift.max(v, r.lowerBound), r.upperBound) }
        func clamp(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double { v.isFinite ? clamp(v, r) : fallback }
        let d = AppSettings()
        var s = self
        if !RoundingRule.allowedUnits.contains(s.rounding.unitMinutes) { s.rounding.unitMinutes = d.rounding.unitMinutes }
        if let c = s.cumulativeStart, !c.isValid { s.cumulativeStart = nil }
        s.utilizationTarget = clamp(s.utilizationTarget, 0.1...1.5, d.utilizationTarget)
        s.graceDays = clamp(s.graceDays, 0...28)
        s.longTimerReminderHours = clamp(s.longTimerReminderHours, 1...12, d.longTimerReminderHours)
        s.idleReminderMinutes = clamp(s.idleReminderMinutes, 1...240)
        s.sleepPromptMinutes = clamp(s.sleepPromptMinutes, 5...120)
        s.autoRefreshMinutes = clamp(s.autoRefreshMinutes, 5...240)
        s.snapshotsKeep = clamp(s.snapshotsKeep, 1...365)
        if var o = s.openingBalance { o.seconds = clamp(o.seconds, -360_000_000...360_000_000); s.openingBalance = o }
        return s
    }
}
