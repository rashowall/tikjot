import Foundation

/// Launch arguments for dev builds: demo mode (`-tikjotDemo`), captures (scripts/capture.sh, run-demo.sh),
/// UI tests and debug aids — all of them run the Debug build. Release ignores every flag, so no argument can
/// switch the everyday tikjot's database, App Group or settings, or pre-fill its UI.
enum LaunchFlags {
    static let args: [String] = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments
        #else
        return []
        #endif
    }()
}

/// Debug/captures: `-ui datePicker,addAbsence` opens those states on launch, so every board in the design can be
/// captured and compared (design audit 2026-10-08). Release builds never see launch flags.
@MainActor
enum DebugUI {
    static func wants(_ state: String) -> Bool {
        let a = LaunchFlags.args
        guard let i = a.firstIndex(of: "-ui"), a.indices.contains(i + 1) else { return false }
        return a[i + 1].split(separator: ",").contains { $0 == state }
    }

    /// Runs `open` a moment after the view appears when `state` was asked for.
    static func open(_ state: String, _ open: @escaping @MainActor () -> Void) {
        guard wants(state) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { open() }
    }
}
