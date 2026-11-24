import Foundation

/// One duration formatter (§14). Lists and sentences use `hm` ("35m", "1h 40m"); `padded` is only for grids whose
/// columns must line up (Week grid, Month ledger); `short` is for the tightest spots (bars, chips).
public enum DurationFormat {
    /// "35m", "1h 05m", "8h 00m", "0m" — no "0h" in front of minutes.
    public static func hm(_ s: Seconds) -> String {
        let neg = s < 0
        let total = abs(s) / 60
        let h = total / 60, m = total % 60
        let body = h == 0 ? "\(m)m" : String(format: "%dh %02dm", h, m)
        return (neg && total > 0 ? "−" : "") + body
    }

    /// Column form for aligned grids: "0h 35m", "1h 05m", "8h 00m".
    public static func padded(_ s: Seconds) -> String {
        let neg = s < 0
        let total = abs(s) / 60
        return (neg && total > 0 ? "−" : "") + String(format: "%dh %02dm", total / 60, total % 60)
    }

    /// Short form for tight places: "1h 30m", "45m", "8h".
    public static func short(_ s: Seconds) -> String {
        let neg = s < 0
        let total = abs(s) / 60
        let h = total / 60, m = total % 60
        let body: String
        if total == 0 { body = "0h" } else if h == 0 { body = "\(m)m" } else if m == 0 { body = "\(h)h" } else { body = "\(h)h \(m)m" }
        return (neg && total > 0 ? "−" : "") + body
    }

    /// Signed balance: "+4h 19m", "−21m", "0m" — never "−0h 21m".
    public static func signed(_ s: Seconds) -> String {
        guard abs(s) >= 60 else { return hm(0) }
        return (s > 0 ? "+" : "") + hm(s)
    }

    /// Percent without a space: "71%".
    public static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// Clock style for running timers: "1:23" or "1:23:45".
    public static func clock(_ s: Seconds, seconds: Bool = false) -> String {
        let s = max(0, s)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return seconds ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", h, m)
    }

    /// Overtime label on rings: "+1:34".
    public static func overClock(_ s: Seconds) -> String { "+" + clock(s) }

    /// Hours decimal for CSV ("1.50").
    public static func decimalHours(_ s: Seconds) -> String {
        String(format: "%.2f", Double(s) / 3600)
    }

    /// Parses durations typed by the user: "1h", "1h 30m", "1:30", "90m", "90", "1.5", "1,5h".
    /// A bare number ≤ 12 means hours, otherwise minutes.
    public static func parse(_ input: String) -> Seconds? {
        let s = input.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !s.isEmpty else { return nil }
        if s.contains(":") {
            let p = s.split(separator: ":")
            guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), m < 60, h >= 0 else { return nil }
            return (h * 60 + m) * 60
        }
        var total = 0.0
        var matched = false
        let scanner = Scanner(string: s)
        scanner.charactersToBeSkipped = .whitespaces
        while !scanner.isAtEnd {
            guard let v = scanner.scanDouble() else { return nil }
            if scanner.scanString("h") != nil {
                total += v * 3600
            } else if scanner.scanString("m") != nil {
                _ = scanner.scanString("in")
                total += v * 60
            } else if scanner.isAtEnd {
                total += (v <= 12 && !matched) ? v * 3600 : v * 60
            } else {
                return nil
            }
            matched = true
        }
        return matched && total >= 0 ? Int(total.rounded()) : nil
    }
}

/// Times typed into time fields: "1020", "10:20", "10.20", "9", "930" → minutes after midnight (§11.1).
public enum TimeOfDayParser {
    public static func parse(_ input: String) -> Int? {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let sep = s.contains(":") ? ":" : (s.contains(".") ? "." : nil)
        let h: Int, m: Int
        if let sep {
            let p = s.split(separator: Character(sep), omittingEmptySubsequences: false)
            guard p.count == 2, let hh = Int(p[0]), let mm = Int(p[1].isEmpty ? "0" : p[1]) else { return nil }
            h = hh; m = mm
        } else {
            guard s.allSatisfy(\.isNumber), let v = Int(s) else { return nil }
            switch s.count {
            case 1, 2: h = v; m = 0
            case 3: h = v / 100; m = v % 100
            case 4: h = v / 100; m = v % 100
            default: return nil
            }
        }
        guard (0...24).contains(h), (0...59).contains(m), h * 60 + m <= 24 * 60 else { return nil }
        return h * 60 + m
    }

    public static func format(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

/// What a START / END / LENGTH field's typed text does when it's committed — on ↩, when focus leaves the field and
/// when the card's Done is clicked (a click doesn't take focus, so the text would otherwise be dropped).
public enum TypedField {
    public enum Outcome<Value: Equatable>: Equatable {
        /// Same value as now — nothing to apply.
        case keep
        case set(Value)
        /// Not a time / length: Done keeps the card open and marks the field.
        case invalid
    }

    /// Typed time of day ("1020", "10:20", "9") on `day`.
    public static func time(_ text: String, current: Date, day: LocalDate, calendar: Calendar) -> Outcome<Date> {
        guard let m = TimeOfDayParser.parse(text) else { return .invalid }
        let new = day.at(minutes: m, in: calendar)
        return new == current ? .keep : .set(new)
    }

    /// Typed length ("2h 2m", "90m", "1:30"), clamped to `range`; zero isn't a length.
    public static func length(_ text: String, current: Int, range: ClosedRange<Int>) -> Outcome<Int> {
        guard let s = DurationFormat.parse(text), s > 0 else { return .invalid }
        let new = min(max(s, range.lowerBound), range.upperBound)
        return new == current ? .keep : .set(new)
    }
}
