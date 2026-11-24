import AppKit
import JiraKit
import SwiftUI
import TikjotDomain
import TikjotPersistence

@main
struct TikjotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Windows are managed by `WindowManager` (menu-bar app); the Settings scene is unused.
        Settings { EmptyView() }
            .commands { AppCommands() }
    }
}

/// Launch flow: open the encrypted database → menu bar → onboarding or nothing (§11.7).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    var model: AppModel?
    var menuBar: MenuBarController?
    var windows = WindowManager()
    var services: BackgroundServices?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    /// Menu-bar-only from the first moment. Set in code, not with LSUIElement in Info.plist: an LSUIElement app that
    /// turns into a regular one (window open, Dock icon) never gets its menus drawn on macOS 26 — the menu bar kept
    /// showing the previous app's (owner 2026-10-08, reproduced with Ghostty and verified fixed).
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Unit tests run inside the app: don't open the real database or show any UI.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        Updates.start()   // Release only; Debug/demo never check
        ClickAway.install()
        HangWatch.start()
        // Demo mode (Debug only) keeps its data in memory, so demo copies may run side by side.
        if LaunchFlags.args.contains("-tikjotDemo") {
            launch()
        } else {
            // A restart (AppRestart) waits up to 5 s for the quitting copy; any other second copy hands over at once.
            launchWhenAlone(waits: ProcessInfo.processInfo.arguments.contains(AppRestart.relaunchFlag) ? 50 : 0)
        }
    }

    /// One tikjot at a time: a second copy (double launch, `open -n`) brings the running one forward and quits
    /// before it opens the database.
    private func launchWhenAlone(waits: Int) {
        let me = ProcessInfo.processInfo.processIdentifier
        let other = Bundle.main.bundleIdentifier.flatMap { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first { $0.processIdentifier != me && !$0.isTerminated }
        }
        guard let other else { return launch() }
        if waits > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.launchWhenAlone(waits: waits - 1) }
            return
        }
        Log.info("another tikjot is running — handing over")
        other.activate()
        NSApp.terminate(nil)
    }

    private func launch() {
        let args = LaunchFlags.args
        let demo = args.contains("-tikjotDemo")
        if demo { Clock.configure(from: args) }
        do {
            let model = try openModel(demo: demo)
            start(with: model)
        } catch PersistenceError.cannotOpen {
            Log.error("database key missing or wrong")
            windows.showCantOpen()
        } catch Keychain.Failure.unavailable(let s) {
            Log.error("database key unreadable: Keychain status \(s)")
            let alert = NSAlert()
            alert.messageText = String(localized: "tikjot can't read its key from the Keychain")
            alert.informativeText = String(localized: "The Keychain is locked or unavailable right now. Nothing was changed. Unlock your Mac's Keychain and try again.")
            alert.addButton(withTitle: String(localized: "Try again"))
            alert.addButton(withTitle: String(localized: "Quit"))
            if alert.runModal() == .alertFirstButtonReturn { launch() } else { NSApp.terminate(nil) }
        } catch {
            Log.error("startup failed: \(SafeError.describe(error))")
            windows.showCantOpen(.failed(SafeError.describe(error)))
        }
    }

    func openModel(demo: Bool) throws -> AppModel {
        if demo {
            let mock = DemoData.makeServer()
            let db = try AppDatabase()
            let model = try AppModel(db: db, demo: true, connections: JiraConnections(mock: mock))
            DemoData.seed(model)
            return model
        }
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: Paths.database.path)
        let key: Data
        switch Keychain.lookup(Keychain.databaseKeyAccount) {
        case .found(let k): key = k
        case .notFound where exists: throw PersistenceError.cannotOpen
        case .notFound: key = try Keychain.newDatabaseKey()
        // Locked / denied is not "missing": never offer Start fresh for it.
        case .failed(let s): throw Keychain.Failure.unavailable(s)
        }
        let db = try AppDatabase(url: Paths.database, key: key)
        return try AppModel(db: db, connections: JiraConnections())
    }

    func start(with model: AppModel) {
        self.model = model
        MenuModel.shared.model = model
        // Week grids follow the Mac's region (Calendar.firstWeekday: 1 = Sunday … 7 = Saturday).
        let fw = Calendar.current.firstWeekday
        LocalDate.weekStartsOn = fw == 1 ? 7 : fw - 1
        model.mergeDuplicateInstances()
        model.applyAppearance()
        menuBar = MenuBarController(model: model)
        services = BackgroundServices(model: model)
        services?.start()
        if !model.settings.onboardingDone && !model.demo {
            windows.showOnboarding(model)
        }
        #if DEBUG
        applyLaunchFlags(model)
        #endif
    }

    #if DEBUG
    /// Dev builds only (captures, UI tests, demo — scripts/capture.sh, run-demo.sh): open windows and pre-fill the UI
    /// from launch flags. Release compiles none of this.
    private func applyLaunchFlags(_ model: AppModel) {
        let args = LaunchFlags.args
        if (model.settings.onboardingDone || model.demo) && args.contains("-openMain") { windows.showMain(model) }
        if args.contains("-openPopover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.menuBar?.showPopover()
                // Debug/capture: open the task picker right away.
                if args.contains("-popoverPicker") { model.popoverEditing = .picker(.timer) }
            }
        }
        if args.contains("-openSettings") { windows.showSettings(model) }
        if args.contains("-openOnboarding") { windows.showOnboarding(model) }
        if let i = args.firstIndex(of: "-appearance"), args.indices.contains(i + 1) {
            let a = args[i + 1]
            model.updateSettings { $0.appearance = a }
        }
        if let i = args.firstIndex(of: "-section"), args.indices.contains(i + 1), let s = MainSection(rawValue: args[i + 1]) { model.mainSelection = s }
        if let i = args.firstIndex(of: "-settingsTab"), args.indices.contains(i + 1), let t = SettingsTab(rawValue: args[i + 1]) { model.settingsTab = t }
        if let i = args.firstIndex(of: "-day"), args.indices.contains(i + 1), let d = LocalDate(args[i + 1]) { model.selectedDay = d }
        // Debug/captures: select today's first entry (inspector), optionally with its task picker open.
        if args.contains("-selectFirst") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let want = args.firstIndex(of: "-selectDesc").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                let list = model.ledger.workEntries(on: model.selectedDay)
                if let e = list.first(where: { want == nil || $0.description == want }) { model.selectedEntryIds = [e.id] }
                if args.contains("-pickTask") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { model.inspectorPickTask = true } }
            }
        }
        // Debug: -demoBig — a beta-sized database (500 more tasks, 3000 more entries) for speed checks (2026-10-22).
        // After the demo's own first send, so the extra history isn't sent to the mock.
        if model.demo, args.contains("-demoBig") { DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard let inst = model.activeInstances.first else { return }
            var c = Changes()
            c.upsertIssues = (0..<500).map { n in
                Issue(instanceId: inst.id, issueId: "big\(n)", key: "OPS_DESK-\(n)", summary: "Set up the release gate for the build pipeline \(n)")
            }
            let day0 = model.today.adding(days: -1).at(minutes: 9 * 60, in: model.timeCalendar)
            c.upsertEntries = (0..<3000).map { n in
                let s = day0.addingTimeInterval(Double(-n) * 3 * 3600)
                return TimeEntry(start: s, end: s.addingTimeInterval(1800), instanceId: inst.id, issueId: "big\(n % 500)",
                                 description: "- Call about the handover sheet \(n % 40)")
            }
            model.applySilently(c)
        } }
        // Debug/captures: -demoMultiline — today's first finished entries get descriptions of several lines (2026-10-22).
        if model.demo, args.contains("-demoMultiline") {
            let texts = ["- Agenda draft for the steering\n- Budget numbers from finance\n- Call with sales; slides for Monday\n- Risks and open points\n- Send to the team\n- Book the room",
                         "Release notes for 2.4\nCall with finance; invite for Monday\nDashboard fixes",
                         "Code review\nRetry tests\nComments for the team"]
            var c = Changes()
            let today = model.ledger.workEntries(on: model.today).filter { !$0.isRunning }
            for (e, t) in zip(today, texts) {
                guard var x = model.data.entries.first(where: { $0.id == e.id }) else { continue }
                x.description = t
                c.upsertEntries.append(x)
            }
            model.applySilently(c)
        }
        // Debug/captures (promo video): -demoRunning "103|Retry logic for card payments|10:05" — this entry runs instead.
        if model.demo, let i = args.firstIndex(of: "-demoRunning"), args.indices.contains(i + 1) {
            let p = args[i + 1].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard p.count == 3 else { return }
                let hm = p[2].split(separator: ":").compactMap { Int($0) }
                if let r = model.runningEntry { model.delete([r]) }
                let issue = model.data.issues.first { $0.issueId == p[0] }
                model.start(issue: issue, description: p[1], at: hm.count == 2 ? model.today.at(minutes: hm[0] * 60 + hm[1], in: model.timeCalendar) : nil)
                model.toast = nil
            }
        }
        // Debug/captures: -selectProject "Internal" (Projects screen), -projectMerge opens its merge sheet.
        if let i = args.firstIndex(of: "-selectProject"), args.indices.contains(i + 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.projectsSelection = model.data.projects.first { $0.name == args[i + 1] }?.id }
        }
        // Debug/captures: -ui twoSelected selects two neighbouring entries of the day (multi-select inspector).
        if DebugUI.wants("twoSelected") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                model.selectedEntryIds = Set(model.ledger.workEntries(on: model.selectedDay).prefix(3).suffix(2).map(\.id))
            }
        }
        if args.contains("-reviewToday") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                // With -day: that day (promo video: a full, finished day).
                let d = model.selectedDay
                model.requestReview(days: [d], title: d == model.today ? "Send today to Jira" : "Send \(Fmt.dayName(d, today: model.today)) to Jira")
            }
        }
        // Debug/captures (website "A day with tikjot"): -demoAway HH:mm — back from a break, the away card from that
        // time until now (the running entry starts no later than it); -demoMondayHole — the Monday card for last Monday.
        if model.demo, let i = args.firstIndex(of: "-demoAway"), args.indices.contains(i + 1) {
            let hm = args[i + 1].split(separator: ":").compactMap { Int($0) }
            // After -demoRunning (0.5 s) has swapped the timer: a card about the replaced one has no owner and is dropped.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                guard hm.count == 2, let r = model.runningEntry else { return }
                let from = model.today.at(minutes: hm[0] * 60 + hm[1], in: model.timeCalendar)
                if r.start > from { model.setRunningStart(from) }
                model.awayPrompt = AwayPrompt(from: from, to: model.now, slept: false, entryId: r.id)
            }
        }
        if model.demo, args.contains("-demoMondayHole") { model.mondayHoles = [model.today.adding(days: -7)] }
        Capture.run(args: args)
        DebugScript.run(args: args, model: model)
        PromoDirector.run(args: args, model: model)
        if args.contains("-showCantOpen") { windows.showCantOpen() }
        if args.contains("-showStartFailed") { windows.showCantOpen(.failed("SQLite error 11: database disk image is malformed")) }
        if args.contains("-showRestorePreview") {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.contentViewController = NSHostingController(rootView: RestoreSnapshotView(date: model.now.addingTimeInterval(-3 * 86400), size: 2_300_000, worklogs: 1284, projects: 6, setAside: 4) { _ in w.close() }.environment(model).themed(model))
            w.center(); w.makeKeyAndOrderFront(nil)
        }
        if args.contains("-testRelaunch") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { AppRestart.relaunch() } }
    }
    #endif

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let model { windows.showMain(model) }
        // A Dock click must also make tikjot the active app, so the menu bar shows its menus.
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { return }
        for url in urls { DeepLink.handle(url, model: model) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The timer keeps running across quits (§7.1) — its start is already stored.
        services?.stop()
    }
}

/// Menu commands (main window shortcuts that need the menu bar: undo/redo, refresh, review & send).
struct AppCommands: Commands {
    var body: some Commands {
        // ⌘Z / ⇧⌘Z: the text being typed has its own undo; otherwise tikjot's data, named (audit U4).
        CommandGroup(replacing: .undoRedo) { UndoRedoItems() }
        CommandGroup(after: .appInfo) {
            if Updates.available {
                Button { Updates.checkNow() } label: {
                    Label(String(localized: "Check for Updates…"), systemImage: Updates.icon)
                }
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                if let m = AppDelegate.shared?.model { AppDelegate.shared?.windows.showSettings(m) }
            }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .printItem) {}   // nothing to print; ⌘P pins a task in the picker
        // View: the main window's sections and the command bar — shortcuts you can find (audit U9).
        CommandGroup(before: .toolbar) {
            ForEach(Array(MainSection.allCases.enumerated()), id: \.element) { i, s in
                Button(s.title) { AppCommands.show(s) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            Divider()
            Button(String(localized: "Command Bar…")) {
                guard let m = AppDelegate.shared?.model else { return }
                AppDelegate.shared?.windows.showMain(m)
                m.showCommandBar = true
            }.keyboardShortcut("k")
            Divider()
        }
        CommandMenu("Go") {
            Button("Refresh from Jira") { Task { await AppDelegate.shared?.model?.refreshAll() } }.keyboardShortcut("r")
            Button("Review & send…") { AppDelegate.shared?.model.map { $0.requestReviewForSelection() } }.keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button(String(localized: "Keyboard Shortcuts")) {
                guard let m = AppDelegate.shared?.model else { return }
                AppDelegate.shared?.windows.showMain(m)
                m.showShortcuts = true
            }
        }
    }

    @MainActor static func show(_ s: MainSection) {
        guard let m = AppDelegate.shared?.model else { return }
        m.mainSelection = s
        AppDelegate.shared?.windows.showMain(m)
    }
}

/// Undo / Redo say what they undo ("Undo Delete") and are disabled when there is nothing; while you type they are
/// the text field's own undo.
private struct UndoRedoItems: View {
    var body: some View {
        let m = MenuModel.shared.model
        let typing = m?.textEditing ?? false
        Button(typing ? String(localized: "Undo") : (m?.undoMenuTitle ?? String(localized: "Undo"))) { m?.undoFromMenu() }
            .keyboardShortcut("z")
            .disabled(!typing && !(m?.canUndo ?? false))
        Button(typing ? String(localized: "Redo") : (m?.redoMenuTitle ?? String(localized: "Redo"))) { m?.redoFromMenu() }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!typing && !(m?.canRedo ?? false))
    }
}

/// The model as the menu bar sees it: observable, so Undo / Redo titles and states follow it from launch on.
@MainActor
@Observable
final class MenuModel {
    static let shared = MenuModel()
    var model: AppModel?
}

/// tikjot:// deep links (widget taps): day/<date>, switch, review, settings — navigation only. Any app or web page
/// can open a tikjot:// URL, so none of them changes data; the widget's Stop / Continue buttons are App Intents.
enum DeepLink {
    @MainActor
    static func handle(_ url: URL, model: AppModel) {
        guard url.scheme == "tikjot" else { return }
        let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
        switch parts.first {
        case "day":
            if let s = parts.dropFirst().first, let d = LocalDate(s) { model.selectedDay = d }
            model.mainSelection = .day
            AppDelegate.shared?.windows.showMain(model)
        case "switch": AppDelegate.shared?.menuBar?.showPopover(); model.popoverEditing = .picker(.timer)
        case "start":
            AppDelegate.shared?.menuBar?.showPopover()
            if model.runningEntry == nil { model.focusTimerDescription() } else { model.popoverEditing = .picker(.timer) }
        case "settings": AppDelegate.shared?.windows.showSettings(model, tab: .jira)
        case "review":
            model.requestReview(days: model.unsentDays(), title: "Send to Jira")
            AppDelegate.shared?.windows.showMain(model)
        default:
            AppDelegate.shared?.windows.showMain(model)
        }
    }
}
