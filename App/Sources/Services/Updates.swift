import Foundation
import Sparkle

/// Sparkle updates (Release builds only). Once a day Sparkle reads the appcast on GitHub (`SUFeedURL`, the
/// `TIKJOT_FEED_URL` build setting) and sends nothing about the user or the Mac (`SUEnableSystemProfiling` NO).
/// A new version is offered in Sparkle's window; it installs only when the user confirms
/// (`SUAllowsAutomaticUpdates` NO). Debug, demo and test builds never start the updater.
@MainActor
enum Updates {
    private static var controller: SPUStandardUpdaterController?

    /// True when "Check for Updates…" can do something: a Release build with the update key. Decided from the
    /// build, not from the started updater — SwiftUI builds the app menu before `applicationDidFinishLaunching`
    /// starts it and doesn't look again, so the menu item never appeared (owner 2026-10-14).
    static let available: Bool = {
        #if DEBUG
        return false
        #else
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return !key.isEmpty
        #endif
    }()

    /// The menu items' icon (macOS 26 shows icons in menus).
    static let icon = "arrow.down.circle"

    static func start() {
        guard available, controller == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    static func checkNow() {
        start()
        controller?.checkForUpdates(nil)
    }
}
