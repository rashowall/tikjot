import AppKit

/// Language changes need a relaunch (macOS loads String Catalogs at launch). The timer survives it (§7.1).
@MainActor
enum AppRestart {
    /// Marks the new copy as a restart: it waits for this one to quit instead of handing over to it (single instance).
    static let relaunchFlag = "-tikjotRelaunch"

    static func offer() {
        let a = NSAlert()
        a.messageText = String(localized: "Restart tikjot to switch the language?")
        a.informativeText = String(localized: "It takes a second. A running timer keeps running.")
        a.addButton(withTitle: String(localized: "Restart now"))
        a.addButton(withTitle: String(localized: "Later"))
        if a.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = [relaunchFlag]
        let url = Bundle.main.bundleURL
        // Start the new instance a moment after we quit, so only one tikjot owns the menu bar. The bundle path goes
        // in as a positional parameter ($0), never into the script text.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; exec /usr/bin/open -n \"$0\" --args \"$1\"", url.path, relaunchFlag]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }
}
