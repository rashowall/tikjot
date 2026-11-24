import Foundation
import Testing
import TikjotDomain
@testable import TikjotSuggestions

/// Beta 2026-10-22 (a tester): typed letters in the task search showed up seconds later. One ranking at the size of a
/// real beta database (≈ 500 tasks, 3000 entries) must stay well inside a frame budget.
@Suite struct PickerSpeedTests {
    @Test func rankingAtBetaSizeIsFast() {
        let inst = UUID()
        let issues = (0..<500).map { n in
            Issue(instanceId: inst, issueId: "\(n)", key: "OPS_DESK-\(n)", summary: "Set up the release gate for the build pipeline \(n)")
        }
        let now = Date()
        let entries = (0..<3000).map { n in
            TimeEntry(start: now.addingTimeInterval(Double(-n) * 3600), end: now.addingTimeInterval(Double(-n) * 3600 + 1800),
                      instanceId: inst, issueId: "\(n % 500)", description: "- Call about the handover sheet \(n)")
        }
        let e = SuggestionEngine()
        let t0 = Date()
        let scored = e.score(issues: issues, entries: entries, now: now, calendar: .current)
        let t1 = Date()
        _ = e.rank("ops gate", candidates: scored)
        let t2 = Date()
        print("score \(Int(t1.timeIntervalSince(t0) * 1000)) ms · rank \(Int(t2.timeIntervalSince(t1) * 1000)) ms")
        // Debug builds are slow; this only catches a ranking that went quadratic.
        #expect(t2.timeIntervalSince(t0) < 1)
    }
}
