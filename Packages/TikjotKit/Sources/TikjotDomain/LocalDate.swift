import Foundation

/// A calendar day without a time or time zone ("2026-10-02").
/// Day assignment always uses the Mac's current time zone (SPEC §6.5).
public struct LocalDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Years tikjot works with. Anything outside (a crafted backup, a typo, a deep link) is refused when
    /// parsed and clamped when built from components, so date arithmetic can't overflow or trap.
    public static let validYears = 1900...2200

    /// Month and day may be out of range (they roll over in date arithmetic); the year is clamped to `validYears`.
    public init(year: Int, month: Int, day: Int) {
        self.year = Swift.min(Swift.max(year, Self.validYears.lowerBound), Self.validYears.upperBound)
        self.month = Swift.min(Swift.max(month, -1200), 1200)
        self.day = Swift.min(Swift.max(day, -36_600), 36_600)
    }

    /// Parses `yyyy-MM-dd` — a real day between 1900 and 2200.
    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              Self.validYears.contains(y), (1...12).contains(m), (1...Self.daysIn(month: m, year: y)).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The day `date` falls on in `calendar`'s time zone. Always counted in the Gregorian calendar (a Hebrew or
    /// Buddhist system calendar would give other years and months); years are clamped to `validYears`.
    public init(_ date: Date, calendar: Calendar) {
        let c = Calendar.gregorian(like: calendar).dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Whether this is a real day within `validYears` (parsed strings always are).
    public var isValid: Bool { LocalDate(description) == self }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // MARK: Codable as a string

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = LocalDate(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    // MARK: Calendar arithmetic (Gregorian, independent of time zone)

    private static let gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private var utcNoon: Date {
        Self.gregorian.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date(timeIntervalSince1970: 43_200)
    }

    public func adding(days: Int) -> LocalDate {
        LocalDate(Self.gregorian.date(byAdding: .day, value: Swift.min(Swift.max(days, -200_000), 200_000), to: utcNoon) ?? utcNoon, calendar: Self.gregorian)
    }

    public func adding(months: Int) -> LocalDate {
        LocalDate(Self.gregorian.date(byAdding: .month, value: Swift.min(Swift.max(months, -6000), 6000), to: utcNoon) ?? utcNoon, calendar: Self.gregorian)
    }

    public func days(until other: LocalDate) -> Int {
        Self.gregorian.dateComponents([.day], from: utcNoon, to: other.utcNoon).day ?? 0
    }

    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public var isoWeekday: Int {
        let w = Self.gregorian.component(.weekday, from: utcNoon) // 1 = Sunday
        return w == 1 ? 7 : w - 1
    }

    public var isoWeek: Int {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.component(.weekOfYear, from: utcNoon)
    }

    public var firstOfMonth: LocalDate { LocalDate(year: year, month: month, day: 1) }

    public var lastOfMonth: LocalDate { firstOfMonth.adding(months: 1).adding(days: -1) }

    public var daysInMonth: Int { lastOfMonth.day }

    /// First day of the week as an ISO weekday (1 = Monday, 7 = Sunday, 6 = Saturday). The app sets it
    /// once at launch from the Mac's region (System Settings › Language & Region › First day of week).
    nonisolated(unsafe) public static var weekStartsOn = 1

    /// First day of the week this date belongs to (Monday unless the region says otherwise).
    public var startOfWeek: LocalDate { startOfWeek(startingOn: Self.weekStartsOn) }

    public func startOfWeek(startingOn first: Int) -> LocalDate { adding(days: -((isoWeekday - first + 7) % 7)) }

    /// ISO weekdays in display order, e.g. [7, 1, 2, 3, 4, 5, 6] when weeks start on Sunday.
    public static var weekdayOrder: [Int] { (0..<7).map { (weekStartsOn - 1 + $0) % 7 + 1 } }

    /// Week number shown to people: the ISO week of the Monday inside this date's week.
    public var weekNumber: Int { startOfWeek.adding(days: (8 - Self.weekStartsOn) % 7).isoWeek }

    public var firstOfYear: LocalDate { LocalDate(year: year, month: 1, day: 1) }

    public var firstOfQuarter: LocalDate { LocalDate(year: year, month: ((month - 1) / 3) * 3 + 1, day: 1) }

    /// Start of this day (00:00) in the given calendar's time zone.
    public func start(in calendar: Calendar) -> Date {
        let calendar = Calendar.gregorian(like: calendar)
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? calendar.startOfDay(for: utcNoon)
    }

    /// Start of the next day — the exclusive end of this day.
    public func end(in calendar: Calendar) -> Date {
        adding(days: 1).start(in: calendar)
    }

    /// Where `date` sits on this day's 24-hour clock face, in seconds after 00:00 (09:00 = 32 400 even on a
    /// daylight-saving day, whose elapsed time since midnight is an hour more or less; the next midnight = 24 h).
    public func clockSeconds(_ date: Date, in calendar: Calendar) -> TimeInterval {
        let tz = calendar.timeZone
        let start = start(in: calendar)
        let shift = tz.secondsFromGMT(for: date) - tz.secondsFromGMT(for: start)
        return date.timeIntervalSince(start) + TimeInterval(shift)
    }

    /// The instant at `minutes` after local midnight (e.g. 8 * 60 = 08:00).
    public func at(minutes: Int, in calendar: Calendar) -> Date {
        let calendar = Calendar.gregorian(like: calendar)
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: minutes / 60, minute: minutes % 60))
            ?? start(in: calendar).addingTimeInterval(TimeInterval(minutes) * 60)
    }
}

extension Calendar {
    /// Gregorian in the Mac's current time zone: the calendar LocalDates are made in.
    public static var gregorianCurrent: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.locale = .current
        c.firstWeekday = Calendar.current.firstWeekday
        return c
    }

    /// `c` itself when it is Gregorian, otherwise a Gregorian calendar in the same time zone.
    public static func gregorian(like c: Calendar) -> Calendar {
        if c.identifier == .gregorian { return c }
        var g = Calendar(identifier: .gregorian)
        g.timeZone = c.timeZone
        g.locale = c.locale
        g.firstWeekday = c.firstWeekday
        return g
    }
}

/// An inclusive range of days.
public struct DateRange: Hashable, Sendable, Codable, Sequence {
    public var start: LocalDate
    public var end: LocalDate

    public init(_ start: LocalDate, _ end: LocalDate) {
        self.start = Swift.min(start, end)
        self.end = Swift.max(start, end)
    }

    public func contains(_ d: LocalDate) -> Bool { d >= start && d <= end }

    public var count: Int { start.days(until: end) + 1 }

    public func makeIterator() -> AnyIterator<LocalDate> {
        var current: LocalDate? = start
        let last = end
        return AnyIterator {
            guard let c = current, c <= last else { return nil }
            // At the end of `validYears` the next day can't go further: stop instead of looping.
            let next = c.adding(days: 1)
            current = next > c ? next : nil
            return c
        }
    }

    public static func month(of d: LocalDate) -> DateRange { DateRange(d.firstOfMonth, d.lastOfMonth) }
    public static func week(of d: LocalDate) -> DateRange { DateRange(d.startOfWeek, d.startOfWeek.adding(days: 6)) }
}
