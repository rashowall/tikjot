import Testing
@testable import TikjotDomain

/// Beta 2026-10-22: multi-line descriptions (⇧↩) — lists show line 1 + "+N", Jira one point per line.
@Suite struct DescriptionLinesTests {
    @Test func linesAndFirst() {
        let d = "- Release notes for 2.4\r\n  - Call with finance; invite for Monday \n\n* Dashboard fixes"
        #expect(DescriptionLines.lines(d) == ["Release notes for 2.4", "Call with finance; invite for Monday", "Dashboard fixes"])
        #expect(DescriptionLines.first(d) == "Release notes for 2.4")
        #expect(DescriptionLines.extra(d) == 2)
        // One line stays as typed, mark included.
        #expect(DescriptionLines.first("- Aktualny stav") == "- Aktualny stav")
        #expect(DescriptionLines.extra("Weekly sync") == 0)
        #expect(DescriptionLines.first("") == "")
    }

    @Test func commentFlattensEveryLine() {
        #expect(DescriptionLines.comment([]) == "")
        #expect(DescriptionLines.comment(["- Aktualny stav"]) == "- Aktualny stav")
        #expect(DescriptionLines.comment(["Sprint review", "Release notes"]) == "• Sprint review\n• Release notes")
        #expect(DescriptionLines.comment(["Prepare agenda", "- Release notes\n- Call; invite\n- prepare agenda"])
                == "• Prepare agenda\n• Release notes\n• Call; invite")
        #expect(DescriptionLines.comment(["- a", "- b"]) == "• a\n• b")
    }

    /// The list's form never counts as a change (#125, #130): old nested marks, plain lines vs points, repeats.
    @Test func commentNormalisationIgnoresTheListForm() {
        let new = DescriptionLines.comment(["- KC Upgrade\n- Rollback", "Testing"])
        #expect(JiraComment.normalized("• - KC Upgrade\n- Rollback\n• Testing") == JiraComment.normalized(new))
        #expect(JiraComment.normalized("KC Upgrade\r\nRollback\n\nTesting") == JiraComment.normalized(new))
        #expect(JiraComment.normalized("* KC Upgrade\n* Rollback\n* Testing\n* testing") == JiraComment.normalized(new))
        #expect(JiraComment.normalized("• KC Upgrade\n• Rollback v2\n• Testing") != JiraComment.normalized(new))
        #expect(JiraComment.normalized("- Standup") == "- Standup")
    }
}
