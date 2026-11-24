import XCTest

/// Base for the UI tests: always demo mode (in-memory data + mock Jira — never real data, never a real Jira)
/// on a frozen clock (Thursday 1 Oct 2026, 16:42), English, light appearance, fixed time zone.
@MainActor
class TikjotUITestCase: XCTestCase {
    static let demoNow = "2026-10-01 16:42"
    var app: XCUIApplication!

    @discardableResult
    func launch(_ extra: String...) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        addTeardownBlock { @MainActor in app.terminate() }
        app.launchArguments = ["-tikjotDemo", "-demoNow", Self.demoNow, "-freezeClock",
                               "-appearance", "light",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"] + extra
        app.launchEnvironment["TZ"] = "Europe/Bratislava"
        app.launchEnvironment["SWIFT_DETERMINISTIC_HASHING"] = "1"
        app.launch()
        // A menu-bar app opens its windows a moment after launch; make sure it's frontmost so the first click
        // acts instead of only activating the window.
        _ = app.windows.firstMatch.waitForExistence(timeout: 10)
        app.activate()
        self.app = app
        return app
    }

    /// Any element by accessibility identifier (SwiftUI maps buttons/texts/groups to different types).
    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func elements(_ id: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: id)
    }

    @discardableResult
    func waitFor(_ id: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let e = element(id)
        if !e.waitForExistence(timeout: timeout) {
            dumpTree()
            XCTFail("\(id) didn't appear", file: file, line: line)
        }
        return e
    }

    func waitUntil(_ timeout: TimeInterval = 10, _ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        dumpTree()
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// On failure: the accessibility tree goes into the test report (attachment) to see what was on screen.
    func dumpTree() {
        let tree = app.debugDescription
        print(tree)
        let a = XCTAttachment(string: tree)
        a.name = "accessibility tree"
        a.lifetime = .deleteOnSuccess
        add(a)
    }

    func click(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        waitFor(id, file: file, line: line).click()
    }

    /// The Day toolbar title ("Thursday 1 October").
    var dayTitle: String { element("period.title").label }

    /// Visible text of an element: on macOS a SwiftUI `Text` exposes it as the value, a button as the label.
    func text(_ id: String) -> String {
        let e = element(id)
        guard e.exists else { return "" }
        return e.label.isEmpty ? (e.value as? String ?? "") : e.label
    }

    /// A static text showing exactly `s` (macOS puts it in the value).
    func staticText(_ s: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", s, s)).firstMatch
    }
}
