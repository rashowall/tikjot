import Foundation
import Testing
@testable import TikjotDomain

/// Stored settings must survive new fields: a missing key keeps its default, the rest keep their stored values.
@Suite struct SettingsDecodingTests {
    /// Every field set to something other than its default.
    static var allChanged: AppSettings {
        var s = AppSettings()
        s.rounding = RoundingRule(unitMinutes: 15, mode: .up)
        s.balancePeriod = .quarter
        s.cumulativeStart = LocalDate(year: 2026, month: 3, day: 1)
        s.openingBalance = OpeningBalance(date: LocalDate(year: 2026, month: 3, day: 1), seconds: -3600)
        s.utilizationTarget = 0.9
        s.graceDays = 3
        s.longTimerReminderHours = 4
        s.idleReminderEnabled = false
        s.idleReminderMinutes = 20
        s.unsentReminderEnabled = false
        s.longTimerReminderEnabled = false
        s.sleepPromptMinutes = 30
        s.monthClosingReminderEnabled = false
        s.fridayRecapEnabled = false
        s.menuBarShowsTime = false
        s.launchAtLogin = false
        s.autoRefreshMinutes = 60
        s.warnEmptyDescription = false
        s.snapshotsEnabled = false
        s.snapshotsKeep = 10
        s.holidayCountry = "CZ"
        s.appearance = "dark"
        s.language = "sk"
        s.soundsEnabled = true
        s.onboardingDone = true
        s.hotkeyOpen = "⌃⌘T"
        s.hotkeyStop = "⌃⌘S"
        return s
    }

    private func json(_ s: AppSettings) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func theFixtureChangesEveryField() {
        // A new setting must be added to `allChanged` (and to `init(from:)`), so the round trip below covers it.
        let defaults = Dictionary(uniqueKeysWithValues: Mirror(reflecting: AppSettings()).children.map { ($0.label ?? "", "\($0.value)") })
        for child in Mirror(reflecting: Self.allChanged).children {
            #expect(defaults[child.label ?? ""] != "\(child.value)", "\(child.label ?? "") is not changed in allChanged")
        }
    }

    @Test func roundTripKeepsEveryValue() throws {
        let s = Self.allChanged
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s)) == s)
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings())) == AppSettings())
    }

    @Test func missingKeyKeepsTheOtherValues() throws {
        var object = try json(Self.allChanged)
        object["graceDays"] = nil
        object["hotkeyStop"] = nil
        object["openingBalance"] = nil
        let decoded = try decode(object)
        var expected = Self.allChanged
        expected.graceDays = AppSettings().graceDays
        expected.hotkeyStop = AppSettings().hotkeyStop
        expected.openingBalance = nil
        #expect(decoded == expected)
        #expect(decoded.rounding == RoundingRule(unitMinutes: 15, mode: .up))
    }

    @Test func emptyObjectIsTheDefaults() throws {
        #expect(try decode([:]) == AppSettings())
    }

    @Test func missingRoundingKeyKeepsTheOther() throws {
        var object = try json(Self.allChanged)
        object["rounding"] = ["mode": "up"]
        #expect(try decode(object).rounding == RoundingRule(unitMinutes: RoundingRule().unitMinutes, mode: .up))
    }

    @Test func unknownKeysAreIgnored() throws {
        var object = try json(Self.allChanged)
        object["aSettingFromANewerVersion"] = true
        object["rounding"] = ["unitMinutes": 15, "mode": "up", "extra": 1]
        #expect(try decode(object) == Self.allChanged)
    }

    @Test func encodingKeepsTheSynthesizedKeys() throws {
        let object = try json(Self.allChanged)
        #expect(Set(object.keys) == Set(Mirror(reflecting: AppSettings()).children.compactMap(\.label)))
        let rounding = try #require(object["rounding"] as? [String: Any])
        #expect(Set(rounding.keys) == ["unitMinutes", "mode"])
    }
}
