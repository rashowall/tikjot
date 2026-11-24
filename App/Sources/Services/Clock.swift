import Foundation

/// The app's notion of "now". Demo mode can shift it (`-demoNow "2026-10-01 16:42"`) to reproduce design moments;
/// `-freezeClock` (with `-demoNow`) stops it there — UI and snapshot tests need a clock that doesn't tick.
enum Clock {
    nonisolated(unsafe) static var offset: TimeInterval = 0
    nonisolated(unsafe) static var frozen: Date?
    static var now: Date { frozen ?? Date().addingTimeInterval(offset) }

    static func configure(from args: [String]) {
        guard let i = args.firstIndex(of: "-demoNow"), args.indices.contains(i + 1), let d = parse(args[i + 1]) else { return }
        offset = d.timeIntervalSinceNow
        if args.contains("-freezeClock") { frozen = d }
    }

    /// "yyyy-MM-dd HH:mm" in the current time zone.
    static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)
    }
}
