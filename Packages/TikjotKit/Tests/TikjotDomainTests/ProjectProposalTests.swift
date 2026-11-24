import Foundation
import Testing
@testable import TikjotDomain

/// The project proposal list (onboarding Projects step, Connect another Jira step 2): what is saved, what "Add" creates.
@Suite struct ProjectProposalTests {
    let a = UUID()
    let b = UUID()

    @Test func pendingSuggestionsRoundTripThroughTheStoredList() throws {
        let pending: [String: (String, UUID)] = ["PAY": ("Payments", a), "HD": ("Helpdesk", b)]
        let list = ProjectProposals.encode(pending)
        #expect(list.map(\.key) == ["HD", "PAY"])
        let decoded = ProjectProposals.decode(try JSONDecoder().decode([ProjectSuggestion].self, from: JSONEncoder().encode(list)))
        #expect(decoded.count == 2)
        #expect(decoded["PAY"]?.0 == "Payments" && decoded["PAY"]?.1 == a)
        #expect(decoded["HD"]?.0 == "Helpdesk" && decoded["HD"]?.1 == b)
    }

    @Test func mergingKeepsWhatIsAlreadyWaiting() {
        let pending: [String: (String, UUID)] = ["PAY": ("Payments", a)]
        let m = ProjectProposals.merging(pending, found: ["PAY": "Payments v2", "CP": "Customer Portal"], instanceId: b)
        #expect(m["PAY"]?.0 == "Payments" && m["PAY"]?.1 == a)
        #expect(m["CP"]?.0 == "Customer Portal" && m["CP"]?.1 == b)
    }

    @Test func planCreatesOnlyTickedRowsWithTheirShownColourAndName() {
        let items = [(a, "CP"), (a, "HD"), (a, "MIG")]
        let p = ProjectProposals.plan(items: items, colors: ["blue", "amber", "green"],
                                      names: ["CP": "  Customer portal ", "HD": "   "], leftOut: ["MIG"], notBillable: ["HD"])
        #expect(p.map(\.key) == ["CP", "HD"])
        #expect(p[0].name == "Customer portal" && p[0].color == "blue" && p[0].billable)
        #expect(p[1].name == "HD" && p[1].color == "amber" && !p[1].billable)
        #expect(p.allSatisfy { $0.instanceId == a })
    }

    @Test func everythingLeftOutCreatesNothing() {
        #expect(ProjectProposals.plan(items: [(a, "CP")], colors: ["blue"], names: [:], leftOut: ["CP"], notBillable: []).isEmpty)
    }
}
