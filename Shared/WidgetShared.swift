import Foundation

/// Minimal data the app hands to the widget through the App Group container (§11.5) —
/// the widget never opens the database.
struct WidgetSnapshot: Codable, Equatable {
    struct Running: Codable, Equatable {
        var description: String
        var key: String?
        var taskName: String
        var color: String
        var start: Date
    }

    struct Row: Codable, Equatable {
        var description: String
        var key: String?
        var taskName: String
        var color: String
        var start: Date
        var end: Date?
        var seconds: Int
        var isAbsence: Bool
    }

    var generatedAt: Date
    var dayTitle: String
    var worked: Int
    var fund: Int
    var allInJira: Bool
    var running: Running?
    var lastTask: Running?
    var rows: [Row]
    var unsentDays: Int
    /// nil | "vacation" | "sickLeave" | "childCare" | "holiday" | "doctor" | "weekend"
    var dayOff: String?
    var dayOffText: String?
    var signedOut: Bool
    var yesterdayWorked: Int
    var balanceText: String

    static let placeholder = WidgetSnapshot(
        generatedAt: Date(), dayTitle: "Thursday", worked: 6 * 3600 + 14 * 60, fund: 8 * 3600, allInJira: false,
        running: Running(description: "Wrap-up notes", key: "PMO-415", taskName: "Steering committee minutes", color: "grape", start: Date().addingTimeInterval(-42 * 60)),
        lastTask: nil,
        rows: [
            Row(description: "Weekly sync", key: "DIV-7", taskName: "Division meetings", color: "jade", start: Date().addingTimeInterval(-4 * 3600), end: Date().addingTimeInterval(-3 * 3600), seconds: 3600, isAbsence: false),
            Row(description: "Retry logic", key: "ABC-981", taskName: "Payment gateway retry", color: "tangerine", start: Date().addingTimeInterval(-3 * 3600), end: Date().addingTimeInterval(-3600), seconds: 7200, isAbsence: false),
        ],
        unsentDays: 2, dayOff: nil, dayOffText: nil, signedOut: false, yesterdayWorked: 7 * 3600 + 50 * 60, balanceText: "−0h 46m")
}

enum WidgetBridge {
    /// From Info.plist (project.yml TIKJOT_APP_GROUP): Release `<team>.com.tikjot.mac`, Debug `<team>.com.tikjot.mac.dev`.
    static var groupID: String { (Bundle.main.object(forInfoDictionaryKey: "TikjotAppGroup") as? String) ?? fallbackGroupID }
    #if DEBUG
    private static let fallbackGroupID = "UPB9VSQ76D.com.tikjot.mac.dev"
    #else
    private static let fallbackGroupID = "UPB9VSQ76D.com.tikjot.mac"
    #endif
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) }
    static var snapshotURL: URL? { container?.appendingPathComponent("widget.json") }
    static var commandsURL: URL? { container?.appendingPathComponent("commands.json") }
    /// Per App Group, so a dev build's widget never pokes the everyday app (Release: `com.tikjot.mac.widget-command`).
    static var commandNotification: String {
        let id = groupID
        let base = id.range(of: "com.tikjot.").map { String(id[$0.lowerBound...]) } ?? "com.tikjot.mac"
        return base + ".widget-command"
    }

    static func write(_ s: WidgetSnapshot) {
        guard let url = snapshotURL, let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Widget side: queue a command and poke the app.
    static func send(_ command: String) {
        guard let url = commandsURL else { return }
        var list = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))) ?? []
        list.append(command)
        try? JSONEncoder().encode(list).write(to: url, options: .atomic)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(commandNotification as CFString), nil, nil, true)
    }

    /// App side.
    static func takeCommands() -> [String] {
        guard let url = commandsURL, let data = try? Data(contentsOf: url) else { return [] }
        try? FileManager.default.removeItem(at: url)
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    nonisolated(unsafe) private static var handler: (() -> Void)?

    static func observeCommands(_ f: @escaping @MainActor () -> Void) {
        handler = { DispatchQueue.main.async { MainActor.assumeIsolated { f() } } }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            WidgetBridge.handler?()
        }, commandNotification as CFString, nil, .deliverImmediately)
    }
}
