import Foundation
import Testing
import TikjotDomain
@testable import TikjotSuggestions

@Suite struct SuggestionTests {
    let inst = UUID()
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Bratislava")!; return c }

    func issue(_ id: String, _ key: String, _ s: String, assigned: Bool = false, done: Bool = false, pinned: Bool = false, order: Int = 0) -> TikjotDomain.Issue {
        TikjotDomain.Issue(instanceId: inst, issueId: id, key: key, summary: s, statusCategory: done ? .done : .indeterminate,
              assignedToMe: assigned, updated: now, pinned: pinned, pinOrder: order)
    }

    func entry(_ id: String, daysAgo: Double, hours: Double, desc: String = "") -> TimeEntry {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return TimeEntry(start: start, end: start.addingTimeInterval(hours * 3600), instanceId: inst, issueId: id, description: desc)
    }

    @Test func ranking() {
        let issues = [issue("1", "ABC-1", "Old work"), issue("2", "ABC-2", "Recent work"), issue("3", "PMO-1", "Assigned"),
                      issue("4", "ABC-4", "Done thing", done: true), issue("5", "INT-1", "Pinned", pinned: true)]
        let entries = [entry("1", daysAgo: 60, hours: 8), entry("2", daysAgo: 1, hours: 2, desc: "Retry"), entry("4", daysAgo: 1, hours: 2)]
        let s = SuggestionEngine().suggestions(issues: issues, entries: entries, now: now, calendar: cal)
        #expect(s.first?.issue.key == "INT-1")      // pinned on top
        #expect(s[1].issue.key == "ABC-2")          // recent usage beats old usage
        #expect(s.first { $0.issue.key == "ABC-2" }?.recentDescriptions == ["Retry"])
        let done = s.firstIndex { $0.issue.key == "ABC-4" }!
        let recent = s.firstIndex { $0.issue.key == "ABC-2" }!
        #expect(done > recent)                      // done demoted
    }

    @Test func todayBoost() {
        let issues = [issue("1", "ABC-1", "Heavy"), issue("2", "ABC-2", "Today")]
        let entries = [entry("1", daysAgo: 2, hours: 6), entry("2", daysAgo: 0.01, hours: 0.2)]
        let s = SuggestionEngine().suggestions(issues: issues, entries: entries, now: now, calendar: cal)
        #expect(s.first?.issue.key == "ABC-2")
    }

    @Test func search() {
        let engine = SuggestionEngine()
        let c = engine.score(issues: [issue("1", "ABC-12", "Payment gateway retry"), issue("2", "ABC-1", "Login"), issue("3", "PMO-415", "Steering")],
                             entries: [], now: now, calendar: cal)
        #expect(engine.search("ABC-1", candidates: c).first?.issue.key == "ABC-1")
        #expect(engine.search("abc", candidates: c).count == 2)
        #expect(engine.search("gateway", candidates: c).map(\.issue.key) == ["ABC-12"])
        #expect(engine.search("pay gate", candidates: c).map(\.issue.key) == ["ABC-12"])
        #expect(engine.search("pgr", candidates: c).isEmpty)   // no scattered letters any more
    }

    // MARK: Ranked picker (row 12)

    func other(_ id: String, _ key: String, _ s: String, done: Bool = false) -> TikjotDomain.Issue {
        issue(id, key, s, done: done)
    }

    /// A project key: "WEB" puts the closed WEB task you logged on top — above letter-scatter hits
    /// (PAY-214 "Dashboard aggregation", FIN-23 "Data governance") and other people's WEB issues.
    @Test func projectKeyBringsLoggedTasksFirst() {
        let engine = SuggestionEngine()
        let issues = [
            issue("142", "WEB-142", "Daily analytics export", done: true),
            issue("120", "WEB-120", "Dashboard filters", done: true),
            issue("157", "WEB-157", "Export schedule settings", assigned: true),
            issue("214", "PAY-214", "Dashboard aggregation", assigned: true),
            issue("23", "FIN-23", "Data governance"),
            other("311", "WEB-311", "Gateway logs cleanup"),
        ]
        let entries = [entry("142", daysAgo: 2, hours: 2), entry("142", daysAgo: 9, hours: 3), entry("142", daysAgo: 20, hours: 1),
                       entry("120", daysAgo: 6, hours: 1), entry("214", daysAgo: 1, hours: 4), entry("23", daysAgo: 1, hours: 4)]
        let c = engine.score(issues: issues, entries: entries, now: now, calendar: cal)
        let remote = [other("311", "WEB-311", "Gateway logs cleanup"), other("298", "WEB-298", "Retention policy draft")]  // Jira's order
        let r = engine.rank("WEB", candidates: c, remote: remote)
        #expect(r.logged.map(\.issue.key) == ["WEB-142", "WEB-120"])          // closed, logged, by how often × how recently
        #expect(r.assigned.map(\.issue.key) == ["WEB-157"])
        #expect(r.more.map(\.issue.key) == ["WEB-311", "WEB-298"])            // others' issues, below
        let keys = (r.logged + r.assigned + r.more).map(\.issue.key)
        #expect(!keys.contains("PAY-214") && !keys.contains("FIN-23"))        // w…e…b scattered in words — gone
        // Lower case works the same.
        #expect(engine.rank("web", candidates: c, remote: remote) == r)
    }

    @Test func wordStartNotSubstring() {
        let engine = SuggestionEngine()
        let c = engine.score(issues: [issue("1", "ABC-1", "Daily analytics export"), issue("2", "ABC-2", "Port forwarding"),
                                      issue("3", "ABC-3", "Účet reporting")],
                             entries: [entry("1", daysAgo: 1, hours: 1), entry("2", daysAgo: 1, hours: 1), entry("3", daysAgo: 1, hours: 1)],
                             now: now, calendar: cal)
        #expect(engine.rank("port", candidates: c).logged.map(\.issue.key) == ["ABC-2"])
        #expect(engine.search("port", candidates: c).map(\.issue.key) == ["ABC-2"])   // "export", "reporting" contain it mid-word
        #expect(engine.search("expo", candidates: c).map(\.issue.key) == ["ABC-1"])
        #expect(engine.search("ucet", candidates: c).map(\.issue.key) == ["ABC-3"])   // accents don't matter
        #expect(engine.search("nalyt", candidates: c).isEmpty)
    }

    /// A pinned task wins a tie of match strength over a more used one; a stronger match still beats a pin.
    @Test func pinnedWinsTies() {
        let engine = SuggestionEngine()
        let c = engine.score(issues: [issue("1", "OPS-7", "Weekly sync"), issue("2", "OPS-8", "Release sync", pinned: true, order: 1)],
                             entries: [entry("1", daysAgo: 1, hours: 8), entry("2", daysAgo: 30, hours: 1)], now: now, calendar: cal)
        #expect(engine.rank("sync", candidates: c).logged.map(\.issue.key) == ["OPS-8", "OPS-7"])
        #expect(engine.rank("ops-7", candidates: c).logged.map(\.issue.key) == ["OPS-7"])
        #expect(engine.rank("weekly", candidates: c).logged.map(\.issue.key) == ["OPS-7"])
    }

    /// Match strength first, usage second: a key-prefix hit beats a much more used name hit.
    @Test func strengthBeforeUsage() {
        let engine = SuggestionEngine()
        let c = engine.score(issues: [issue("1", "OPS-7", "Weekly ops sync"), issue("2", "OPS-71", "Release")],
                             entries: [entry("1", daysAgo: 1, hours: 8), entry("2", daysAgo: 30, hours: 1)], now: now, calendar: cal)
        #expect(engine.rank("ops-7", candidates: c).logged.map(\.issue.key) == ["OPS-7", "OPS-71"])
        #expect(engine.rank("ops", candidates: c).logged.map(\.issue.key) == ["OPS-7", "OPS-71"])
        #expect(engine.rank("release", candidates: c).logged.map(\.issue.key) == ["OPS-71"])
    }

    /// A task found among your Jira worklogs (source "logged") counts as yours even without entries here.
    @Test func jiraLoggedCountsAsYours() {
        let engine = SuggestionEngine()
        var closed = issue("9", "WEB-9", "Old migration", done: true)
        closed.sources = ["search", "logged"]
        let r = engine.rank("WEB", candidates: [], remote: [closed, other("10", "WEB-10", "Someone's")])
        #expect(r.logged.map(\.issue.key) == ["WEB-9"])
        #expect(r.more.map(\.issue.key) == ["WEB-10"])
    }

    @Test func similarDescriptions() {
        let engine = SuggestionEngine()
        let entries = [entry("1", daysAgo: 3, hours: 1, desc: "Review checkout flow with UX"),
                       entry("2", daysAgo: 1, hours: 5, desc: "Review retry logic"),
                       entry("3", daysAgo: 1, hours: 5, desc: "Budget for the team")]
        let c = engine.score(issues: [issue("1", "PAY-214", "Checkout redesign"), issue("2", "PAY-220", "Payment gateway retry"),
                                      issue("3", "FIN-23", "Budget")], entries: entries, now: now, calendar: cal)
        // More shared words first (3 of 3 beat 1 of 3, though PAY-220 is used more); FIN-23 shares none.
        #expect(engine.similar(to: "Review checkout flow", candidates: c, entries: entries).map(\.issue.key) == ["PAY-214", "PAY-220"])
        #expect(engine.similar(to: "the", candidates: c, entries: entries).isEmpty)
    }
}
