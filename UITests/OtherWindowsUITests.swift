import XCTest

/// Settings, onboarding and the menu-bar popover (SPEC §18).
final class SettingsUITests: TikjotUITestCase {
    func testSwitchingTabs() {
        launch("-openSettings")
        waitFor("settings.content.general")
        for tab in ["jira", "workTime", "tracking", "backup", "general"] {
            click("settings.tab.\(tab)")
            waitFor("settings.content.\(tab)")
        }
    }
}

final class OnboardingUITests: TikjotUITestCase {
    func testFirstStepsClickThrough() {
        launch("-openOnboarding")
        waitFor("onboarding.step.welcome")
        click("onboarding.next")
        waitFor("onboarding.step.jira")
        click("onboarding.withoutJira")
        waitFor("onboarding.step.work")
        click("onboarding.back")
        waitFor("onboarding.step.jira")
    }

    /// `-onboardingStep 3` (capture flag) opens work time on the Jira path: Continue goes to the import.
    func testStepFlagFollowsJiraPath() {
        launch("-openOnboarding", "-onboardingStep", "3")
        waitFor("onboarding.step.work")
        click("onboarding.next")
        waitFor("onboarding.step.importHistory")
    }
}

/// The status-item popover can't be clicked open reliably from XCUITest (the menu bar belongs to SystemUIServer
/// / ControlCenter), so the app opens it itself (`-openPopover`) and the test checks its content.
final class PopoverUITests: TikjotUITestCase {
    func testPopoverOpensWithToday() {
        launch("-openPopover")
        let popover = waitFor("popover", timeout: 10)
        // The capsule shows the running entry; today's list follows.
        XCTAssertTrue(popover.buttons["Wrap-up notes"].waitForExistence(timeout: 5), "running entry in the capsule")
        XCTAssertTrue(popover.buttons["Stop timer"].exists)
        XCTAssertTrue(staticText("Today").exists, "today's list")
        XCTAssertTrue(popover.buttons["Review & send"].exists)
    }

    /// ⌘O in the popover opens the main window (the ⋯ menu shows it; found in testing that it did nothing).
    func testCommandOOpensMainWindow() {
        launch("-openPopover")
        let popover = waitFor("popover", timeout: 10)
        XCTAssertTrue(popover.buttons["Stop timer"].waitForExistence(timeout: 5))
        popover.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(element("sidebar.day").waitForExistence(timeout: 5), "main window opened")
    }

    /// Typing a new description and pressing Stop without ↩ keeps it on the stopped entry,
    /// leaves the idle field empty, and the next start shows its own description (found in testing).
    func testDescriptionTypedThenStopped() {
        launch("-openPopover")
        let popover = waitFor("popover", timeout: 10)
        let desc = popover.buttons["Wrap-up notes"]
        XCTAssertTrue(desc.waitForExistence(timeout: 5))
        desc.click()
        let field = popover.textFields["capsule.descriptionField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Minutes sent")
        popover.buttons["Stop timer"].click()
        let idle = popover.textFields["capsule.idleField"]
        XCTAssertTrue(idle.waitForExistence(timeout: 3), "idle capsule after stop")
        XCTAssertEqual((idle.value as? String) ?? "", "", "the edited description must not stay in the idle field")
        // Day-list rows are combined accessibility elements (button trait) whose label starts with the description.
        let kept = popover.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Minutes sent")).firstMatch
        XCTAssertTrue(kept.waitForExistence(timeout: 3), "stopped entry kept the typed description")
    }
}
