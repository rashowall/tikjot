import Foundation
import TikjotDomain

/// Date & time display following macOS region settings (§14), in the app's language.
enum Fmt {
    @MainActor static var locale: Locale {
        Locale(identifier: AppDelegate.shared?.model?.language == "sk" ? "sk_SK" : (Locale.current.identifier.hasPrefix("sk") ? "en_GB" : Locale.current.identifier))
    }

    @MainActor private static func formatter(_ template: String) -> DateFormatter {
        let key = "\(locale.identifier)|\(template)"
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        cache[key] = f
        return f
    }

    @MainActor private static var cache: [String: DateFormatter] = [:]

    @MainActor static func date(_ d: LocalDate) -> Date { d.start(in: Calendar.current).addingTimeInterval(12 * 3600) }

    /// "Thursday"
    @MainActor static func weekday(_ d: LocalDate) -> String { formatter("EEEE").string(from: date(d)).capitalizedFirst }
    /// "Thu"
    @MainActor static func weekdayShort(_ d: LocalDate) -> String { formatter("EEE").string(from: date(d)).capitalizedFirst }
    /// "Thursday, 1 October"
    @MainActor static func long(_ d: LocalDate) -> String {
        formatter("EEEEdMMMM").string(from: date(d)).replacingOccurrences(of: ",", with: "").capitalizedFirst
    }
    /// "Thu 1 Oct"
    @MainActor static func short(_ d: LocalDate) -> String {
        // The design writes "Thu 1 Oct" — the locale's template adds a comma ("Thu, 1 Oct").
        formatter("EEEdMMM").string(from: date(d)).replacingOccurrences(of: ",", with: "").capitalizedFirst
    }
    /// "1 Oct"
    @MainActor static func dayMonth(_ d: LocalDate) -> String { formatter("dMMM").string(from: date(d)) }
    /// "1 Oct 2026"
    @MainActor static func dayMonthYear(_ d: LocalDate) -> String { formatter("dMMMyyyy").string(from: date(d)) }
    /// "1 October 2026"
    @MainActor static func dayMonthYearLong(_ d: LocalDate) -> String { formatter("dMMMMyyyy").string(from: date(d)) }
    /// "October 2026"
    @MainActor static func monthYear(_ d: LocalDate) -> String { formatter("LLLLyyyy").string(from: date(d)).capitalizedFirst }
    /// "October"
    @MainActor static func monthName(_ d: LocalDate) -> String { formatter("LLLL").string(from: date(d)).capitalizedFirst }
    /// "Oct"
    @MainActor static func monthShort(_ d: LocalDate) -> String { formatter("LLL").string(from: date(d)).capitalizedFirst }

    /// "today", "yesterday", or the weekday.
    @MainActor static func dayName(_ d: LocalDate, today: LocalDate) -> String {
        if d == today { return String(localized: "today") }
        if d == today.adding(days: -1) { return String(localized: "yesterday") }
        if d.days(until: today) < 7 && d < today { return weekday(d) }
        return short(d)
    }

    @MainActor static func dayTitle(_ d: LocalDate, today: LocalDate) -> String {
        if d == today { return String(localized: "Today") }
        if d == today.adding(days: -1) { return String(localized: "Yesterday") }
        return weekday(d)
    }

    /// "10:10" (24 h unless the region says otherwise).
    @MainActor static func time(_ t: Date) -> String { formatter("jjmm").string(from: t) }

    @MainActor static func range(_ a: Date, _ b: Date?) -> String {
        b.map { "\(time(a))–\(time($0))" } ?? "\(time(a))–\(String(localized: "now"))"
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
