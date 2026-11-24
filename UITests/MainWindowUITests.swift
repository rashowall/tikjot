import XCTest

/// Main window flows (SPEC §18): Day timeline, day navigation, sections, add entry, absence, review & send.
final class MainWindowUITests: TikjotUITestCase {
    func testDayShowsTimelineEntries() {
        launch("-openMain")
        waitFor("screen.day")
        waitFor("day.entry")
        XCTAssertGreaterThanOrEqual(elements("day.entry").count, 4, "today's demo entries")
        XCTAssertTrue(dayTitle.contains("1 October"), dayTitle)
    }

    func testDayNavigationPrevNextToday() {
        launch("-openMain")
        waitFor("day.entry")
        XCTAssertTrue(dayTitle.contains("1 October"), dayTitle)
        click("period.prev")
        waitUntil(5, "yesterday") { dayTitle.contains("30 September") }
        click("period.next")
        click("period.next")
        waitUntil(5, "tomorrow") { dayTitle.contains("2 October") }
        // Tomorrow hasn't started: the empty state says so.
        waitFor("day.empty.title")
        XCTAssertEqual(text("day.empty.title"), "This day hasn't started")
        click("period.today")
        waitUntil(5, "today") { dayTitle.contains("1 October") }
        waitFor("day.entry")
    }

    func testSwitchSections() {
        launch("-openMain")
        waitFor("screen.day")
        for section in ["week", "month", "unsent", "statistics", "projects", "day"] {
            click("sidebar.\(section)")
            waitFor("screen.\(section)")
        }
    }

    func testAddEntryAppearsOnTimeline() {
        launch("-openMain")
        waitFor("day.entry")
        let before = elements("day.entry").count
        click("period.add")
        // The new entry is selected and the inspector shows it: describe it there.
        let field = waitFor("inspector.description")
        field.click()
        field.typeText("UI test entry\r")
        waitUntil(5, "a new block") { self.elements("day.entry").count == before + 1 }
        let added = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'day.entry' AND label CONTAINS 'UI test entry'"))
        XCTAssertTrue(added.firstMatch.waitForExistence(timeout: 5), "the described entry is on the timeline")
    }

    func testAddAndRemoveVacationDay() {
        launch("-openMain")
        waitFor("day.entry")
        click("period.next") // Fri 2 Oct — hasn't started
        waitUntil(5, "tomorrow") { dayTitle.contains("2 October") }
        click("day.addAbsence")
        waitFor("absence.type.vacation")
        click("absence.save")
        waitUntil(5, "vacation day") { self.text("day.empty.title") == "Vacation" }
        let subtitle = element("period.title").value as? String ?? ""
        XCTAssertTrue(subtitle.contains("vacation"), "fund line names the absence: \(subtitle)")
        click("day.editAbsence")
        click("absence.remove")
        waitUntil(5, "absence removed") { self.text("day.empty.title") == "This day hasn't started" }
        XCTAssertFalse(element("day.editAbsence").exists)
    }

    func testReviewAndSendToMockJira() {
        launch("-openMain")
        waitFor("day.entry")
        click("period.review")
        waitFor("review.title")
        XCTAssertEqual(text("review.title"), "Send today to Jira")
        click("review.send")
        waitFor("review.resultTitle", timeout: 15)
        waitUntil(15, "send result") { self.text("review.resultTitle") != "Sending…" }
        XCTAssertEqual(text("review.resultTitle"), "Today is in Jira")
        click("review.done")
        waitUntil(5, "sheet closed") { !self.element("review.resultTitle").exists }
    }
}
