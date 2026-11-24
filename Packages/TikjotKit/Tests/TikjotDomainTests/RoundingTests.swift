import Foundation
import Testing
@testable import TikjotDomain

@Suite struct RoundingTests {
    @Test(arguments: [
        (5, RoundingRule.Mode.up, 112 * 60, 115 * 60),
        (5, .up, 115 * 60, 115 * 60),
        (5, .up, 115 * 60 + 1, 120 * 60),
        (5, .down, 114 * 60, 110 * 60),
        (5, .nearest, 112 * 60, 110 * 60),
        (5, .nearest, 112 * 60 + 30, 115 * 60),
        (15, .up, 61 * 60, 75 * 60),
        (30, .down, 20 * 60, 30 * 60),   // min one unit
        (30, .nearest, 10, 30 * 60),     // min one unit
        (0, .up, 90 * 60 + 29, 90 * 60), // off → whole minutes
        (0, .up, 20, 60),                // off, positive → at least a minute
        (5, .up, 0, 0),
    ] as [(Int, RoundingRule.Mode, Int, Int)])
    func matrix(unit: Int, mode: RoundingRule.Mode, raw: Int, expected: Int) {
        #expect(RoundingRule(unitMinutes: unit, mode: mode).apply(raw) == expected)
    }

    @Test func newSettingsRoundToNearestFiveButStoredOnesKeepTheirRule() throws {
        #expect(AppSettings().rounding == RoundingRule(unitMinutes: 5, mode: .nearest))
        #expect(AppSettings().rounding.apply(112 * 60) == 110 * 60)
        var stored = AppSettings()
        stored.rounding = RoundingRule(unitMinutes: 5, mode: .up)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(stored))
        #expect(decoded.rounding.mode == .up)
    }
}
