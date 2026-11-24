import Foundation
import TikjotDomain

/// Country holiday definitions as data files (SPEC §6.8), one `Resources/<ISO country>.json` per country.
///
/// Only **days off** (non-working public holidays) belong in a file. Holidays that always fall on a
/// Sunday (Easter Sunday, Whit Sunday) or always on a Saturday are left out — they never change a workday.
///
/// File format:
/// ```
/// {
///   "country": "CZ",                              // ISO 3166-1 alpha-2, = file name
///   "name": { "en": "Czechia", "sk": "Česko", "cs": "Česko" },
///   "source": "law / official page the data relies on",
///   "notes": "free text: regional extras, caveats",
///   "substitute": "nextWorkday",                  // optional default for every entry (see below)
///   "holidays": [
///     { "id": "new-year", "rule": { "fixed": "01-01" }, "name": { "en": "…", "sk": "…", "cs": "…" } },
///     …
///   ]
/// }
/// ```
/// Entry fields: `id`, `rule`, `name` (per language code; falls back to "en"), and optional
/// `validFrom` / `validTo` (years, inclusive), `exceptYears` ([years] the entry does not apply),
/// `substitute` (overrides the file default; "none" switches it off).
///
/// A `rule` has exactly one of:
/// - `"fixed": "MM-DD"`
/// - `"easter": n` — n days after Western (Gregorian) Easter Sunday (negative = before)
/// - `"orthodoxEaster": n` — n days after Orthodox (Julian) Easter Sunday
/// - `"nthWeekday": { "month": 5, "weekday": 1, "n": -1 }` — ISO weekday 1 = Mon … 7 = Sun;
///   n = 1…5 counts from the start of the month, -1 = last
/// - `"weekdayOnOrAfter": { "date": "06-19", "weekday": 5, "orIfWeekday": [5] }` — first such weekday
///   on or after the date (Midsummer Eve = Fri 19–25 Jun); optional `orIfWeekday`: the date itself
///   when it falls on one of those weekdays (IE St Brigid's Day: first Mon of Feb, or 1 Feb if a Friday)
///
/// `substitute` (when the holiday falls on Saturday or Sunday):
/// - `"nextWorkday"` — the next Mon–Fri that is not already a day off (UK)
/// - `"nearestWeekday"` — Saturday → the Friday before, Sunday → the Monday after (US federal)
/// - `"none"` (default)
public struct HolidayDefinition: Codable, Sendable {
    public struct NthWeekday: Codable, Sendable {
        public var month: Int
        public var weekday: Int
        public var n: Int
    }

    public struct WeekdayOnOrAfter: Codable, Sendable {
        public var date: String
        public var weekday: Int
        public var orIfWeekday: [Int]?
    }

    public struct Rule: Codable, Sendable {
        public var fixed: String?
        public var easter: Int?
        public var orthodoxEaster: Int?
        public var nthWeekday: NthWeekday?
        public var weekdayOnOrAfter: WeekdayOnOrAfter?
    }

    public struct Entry: Codable, Sendable {
        public var id: String
        public var rule: Rule
        public var validFrom: Int?
        public var validTo: Int?
        public var exceptYears: [Int]?
        public var substitute: String?
        public var name: [String: String]
    }

    public var country: String
    public var name: [String: String]
    public var source: String?
    public var notes: String?
    public var substitute: String?
    public var holidays: [Entry]

    /// Display name of the country in `language` (falls back to English, then the code).
    public func displayName(language: String) -> String { name[language] ?? name["en"] ?? country }

    public func holidays(in year: Int, language: String) -> [Holiday] {
        var placed: [(date: LocalDate, name: String, substitute: String)] = []
        for h in holidays {
            if let f = h.validFrom, year < f { continue }
            if let t = h.validTo, year > t { continue }
            if h.exceptYears?.contains(year) == true { continue }
            guard let date = Self.date(of: h.rule, in: year) else { continue }
            placed.append((date, h.name[language] ?? h.name["en"] ?? h.id, h.substitute ?? substitute ?? "none"))
        }
        // Stable by file order for equal dates.
        placed = placed.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)

        // Days off that are already taken (fixed weekday holidays) — substitutes must not land on them.
        var taken = Set(placed.filter { $0.date.isoWeekday <= 5 || $0.substitute == "none" }.map(\.date))
        var result: [Holiday] = []
        for p in placed {
            var date = p.date
            if p.date.isoWeekday >= 6 {
                switch p.substitute {
                case "nextWorkday":
                    date = p.date.adding(days: 8 - p.date.isoWeekday)
                    while date.isoWeekday >= 6 || taken.contains(date) { date = date.adding(days: 1) }
                    taken.insert(date)
                case "nearestWeekday":
                    date = p.date.adding(days: p.date.isoWeekday == 6 ? -1 : 1)
                    taken.insert(date)
                default:
                    break
                }
            }
            // Two holidays on one day (e.g. RO Children's Day = Whit Monday) → one day off, both names.
            if let i = result.firstIndex(where: { $0.date == date }) {
                result[i].name += " / " + p.name
            } else {
                result.append(Holiday(date: date, name: p.name))
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    static func date(of rule: Rule, in year: Int) -> LocalDate? {
        if let fixed = rule.fixed {
            return monthDay(fixed, year)
        } else if let offset = rule.easter {
            return HolidayEngine.easterSunday(year).adding(days: offset)
        } else if let offset = rule.orthodoxEaster {
            return HolidayEngine.orthodoxEasterSunday(year).adding(days: offset)
        } else if let r = rule.nthWeekday {
            if r.n > 0 {
                let first = LocalDate(year: year, month: r.month, day: 1)
                let d = first.adding(days: (r.weekday - first.isoWeekday + 7) % 7 + (r.n - 1) * 7)
                return d.month == r.month ? d : nil
            } else {
                let last = LocalDate(year: year, month: r.month, day: 1).lastOfMonth
                let d = last.adding(days: -((last.isoWeekday - r.weekday + 7) % 7) + (r.n + 1) * 7)
                return d.month == r.month ? d : nil
            }
        } else if let r = rule.weekdayOnOrAfter, let start = monthDay(r.date, year) {
            if r.orIfWeekday?.contains(start.isoWeekday) == true { return start }
            return start.adding(days: (r.weekday - start.isoWeekday + 7) % 7)
        }
        return nil
    }

    private static func monthDay(_ s: String, _ year: Int) -> LocalDate? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return LocalDate(year: year, month: p[0], day: p[1])
    }
}

public enum HolidayEngine {
    private static let countryCodes = [
        "AT", "BE", "CH", "CZ", "DE", "DK", "ES", "FI", "FR", "GB", "HR", "HU", "IE", "IT",
        "NL", "NO", "PL", "PT", "RO", "SE", "SI", "SK", "UA", "US",
    ]

    private static let definitions: [String: HolidayDefinition] = {
        var d: [String: HolidayDefinition] = [:]
        for c in countryCodes {
            guard let url = Bundle.module.url(forResource: c, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let def = try? JSONDecoder().decode(HolidayDefinition.self, from: data) else { continue }
            d[c] = def
        }
        return d
    }()

    /// ISO country codes with a holiday file, sorted by English country name.
    public static let availableCountries: [String] = countryCodes
        .filter { definitions[$0] != nil }
        .sorted { definitions[$0]!.displayName(language: "en") < definitions[$1]!.displayName(language: "en") }

    /// Codes sorted by their display name in `language` (for pickers).
    public static func countries(sortedFor language: String) -> [String] {
        availableCountries.sorted {
            countryName($0, language: language).compare(countryName($1, language: language), locale: Locale(identifier: language)) == .orderedAscending
        }
    }

    /// Display name of a country from its file (`name` in `language`, falling back to English, then the code).
    public static func countryName(_ country: String, language: String) -> String {
        definition(for: country)?.displayName(language: language) ?? country
    }

    /// The holiday country to suggest for a region code (e.g. `Locale.current.region?.identifier`):
    /// the region if we have its file (UK → GB), else Slovakia.
    public static func defaultCountry(forRegion region: String?) -> String {
        guard var r = region?.uppercased() else { return "SK" }
        if r == "UK" { r = "GB" }
        return definitions[r] != nil ? r : "SK"
    }

    public static func definition(for country: String) -> HolidayDefinition? {
        definitions[country.uppercased()]
    }

    public static func holidays(country: String, years: ClosedRange<Int>, language: String = "en") -> [Holiday] {
        guard let def = definition(for: country) else { return [] }
        return years.flatMap { def.holidays(in: $0, language: language) }
    }

    /// Anonymous Gregorian algorithm (Meeus/Jones/Butcher).
    public static func easterSunday(_ year: Int) -> LocalDate {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        return LocalDate(year: year, month: month, day: day)
    }

    /// Orthodox Easter (Meeus Julian algorithm), converted to the Gregorian calendar.
    public static func orthodoxEasterSunday(_ year: Int) -> LocalDate {
        let a = year % 4
        let b = year % 7
        let c = year % 19
        let d = (19 * c + 15) % 30
        let e = (2 * a + 4 * b - d + 34) % 7
        let month = (d + e + 114) / 31
        let day = ((d + e + 114) % 31) + 1
        // Julian → Gregorian offset: 13 days for 1900–2099.
        let offset = year / 100 - year / 400 - 2
        return LocalDate(year: year, month: month, day: day).adding(days: offset)
    }
}
