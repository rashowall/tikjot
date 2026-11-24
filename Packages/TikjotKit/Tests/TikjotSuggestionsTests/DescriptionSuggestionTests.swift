import Foundation
import Testing
import TikjotDomain
@testable import TikjotSuggestions

@Suite struct DescriptionSuggestionTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func e(_ d: String, issue: String? = nil, daysAgo: Double, _ inst: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!) -> TimeEntry {
        let s = now.addingTimeInterval(-daysAgo * 86400)
        return TimeEntry(start: s, end: s + 1800, instanceId: issue == nil ? nil : inst, issueId: issue, description: d)
    }

    @Test func emptyQueryShowsRecentCombinations() {
        let r = DescriptionSuggestions.suggest(entries: [e("Standup", issue: "3", daysAgo: 3), e("Weekly sync", issue: "7", daysAgo: 1),
                                                         e("Weekly sync", issue: "7", daysAgo: 8), e("", issue: "9", daysAgo: 0)], query: "", now: now)
        #expect(r.map(\.description) == ["Weekly sync", "Standup"])   // newest first, merged, empty descriptions skipped
        #expect(r.first?.count == 2 && r.first?.issueId == "7")
    }

    @Test func typingPrefersStartOfDescriptionThenWordsThenFrequency() {
        let entries = [e("Prepare agenda for steering", issue: "1", daysAgo: 1), e("Steering committee minutes", issue: "2", daysAgo: 5),
                       e("Steering committee minutes", issue: "2", daysAgo: 6), e("Code review", issue: "3", daysAgo: 0), e("Old steering", daysAgo: 90)]
        let r = DescriptionSuggestions.suggest(entries: entries, query: "stee", now: now)
        #expect(r.map(\.description) == ["Steering committee minutes", "Prepare agenda for steering"])  // 90 days old drops out
    }

    @Test func sameTextWithDifferentTasksStaysSeparate() {
        let r = DescriptionSuggestions.suggest(entries: [e("Meeting", issue: "1", daysAgo: 1), e("Meeting", issue: "2", daysAgo: 2)], query: "mee", now: now)
        #expect(r.count == 2)
    }
}
