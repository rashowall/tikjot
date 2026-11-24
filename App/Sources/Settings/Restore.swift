import AppKit
import SwiftUI
import TikjotDomain
import TikjotPersistence

@MainActor
enum Restore {
    /// A backup that opens but holds dates or durations tikjot can't use (BackupValidation): nothing was changed.
    static var outOfRangeMessage: String {
        String(localized: "This backup has dates or times tikjot can't use (before 1900, after 2200, or an entry of 48 hours or more). Nothing was changed.")
    }

    static func reload(_ model: AppModel) { model.reloadFromDatabase() }

    /// Restore a daily snapshot (design "App · restore from snapshot"): what comes back and what is set aside first.
    static func snapshot(_ url: URL, model: AppModel) {
        // Read-only: restoring must not touch the snapshot (its mtime dates it, and it may be needed again).
        guard let key = Keychain.read(Keychain.databaseKeyAccount), let snap = try? AppDatabase.loadSnapshot(at: url, key: key).validated() else {
            model.showToast(String(localized: "Couldn't open this snapshot."))
            return
        }
        let snapDate = SnapshotManager.date(of: url)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        let newer = newerThan(snap, snapDate: snapDate, model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        let view = RestoreSnapshotView(date: snapDate, size: size, worklogs: snap.groups.count, projects: snap.projects.count, setAside: newer.count) { ok in
            NSApp.stopModal(withCode: ok ? .OK : .cancel)
        }
        window.contentViewController = NSHostingController(rootView: view.environment(model).themed(model))
        window.center()
        let result = NSApp.runModal(for: window)
        window.orderOut(nil)
        guard result == .OK else { return }
        Task {
            // Not while a send or refresh is writing: it would put back what the restore just replaced.
            await model.engine.pauseWrites()
            replace(with: snap, newer: newerThan(snap, snapDate: snapDate, model: model), key: key, model: model)
            await model.engine.resumeWrites()
        }
    }

    /// Entries tracked (or changed) after the snapshot: set aside before it comes back.
    private static func newerThan(_ snap: DataSnapshot, snapDate: Date, model: AppModel) -> [TimeEntry] {
        let known = Set(snap.entries.map(\.id))
        return model.data.entries.filter { !known.contains($0.id) || $0.updatedAt > snapDate }
    }

    private static func replace(with snap: DataSnapshot, newer: [TimeEntry], key: Data, model: AppModel) {
        do {
            if !newer.isEmpty {
                try FileManager.default.createDirectory(at: Paths.setAside, withIntermediateDirectories: true)
                var aside = DataSnapshot()
                aside.entries = newer
                aside.issues = model.data.issues
                aside.projects = model.data.projects
                // Encrypted with the database key (BackupCodec.openSetAside reads it back), never plaintext JSON.
                try BackupCodec.sealSetAside(aside, databaseKey: key)
                    .write(to: Paths.setAside.appendingPathComponent("set-aside-\(Int(Clock.now.timeIntervalSince1970)).tikjotaside"))
            }
            try model.db.replaceAll(with: snap)
            model.reloadFromDatabase()
            model.showToast(String(localized: "Restored · \(newer.count) newer entries set aside"), actionTitle: newer.isEmpty ? nil : String(localized: "Show")) {
                NSWorkspace.shared.open(Paths.setAside)
            }
        } catch {
            Log.error("restore failed: \(SafeError.describe(error))")
            model.showToast(String(localized: "Couldn't restore — \(SafeError.describe(error))"))
        }
    }

    /// "Removes everything tikjot stores on this Mac": data (wiped, compacted, WAL truncated), snapshots,
    /// set-aside files, logs, the widget's files, preferences and every Keychain item but the key of the kept (empty) database.
    /// No send, undo or refresh runs meanwhile (the engine's writer lock); a pending retry is dropped. If the
    /// data can't be wiped, nothing else is removed and the user is told.
    static func deleteAll(_ model: AppModel) async {
        model.connections.sendRetry?.cancel()
        model.connections.sendRetry = nil
        model.connections.retryGroups = []
        model.offlineRetry?.cancel()
        model.offlineRetry = nil
        model.networkRetry?.cancel()
        model.networkRetry = nil
        model.markAllReachable()
        await model.engine.pauseWrites()
        do {
            try model.db.wipe()
        } catch {
            await model.engine.resumeWrites()
            Log.error("wipe failed: \(SafeError.describe(error))")
            model.reloadFromDatabase()
            model.showToast(String(localized: "Couldn't delete your data — nothing was removed. \(SafeError.describe(error))"))
            return
        }
        NotificationService.shared.removeAll()
        if !model.demo {
            model.connections.forgetAll()
            Keychain.deleteAll(except: [Keychain.databaseKeyAccount])
            let fm = FileManager.default
            for u in [Paths.snapshots, Paths.setAside, Paths.logs, WidgetBridge.snapshotURL, WidgetBridge.commandsURL].compactMap({ $0 }) {
                try? fm.removeItem(at: u)
            }
            if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        }
        model.reloadFromDatabase()
        await model.engine.resumeWrites()
        if let d = AppDelegate.shared { d.windows.showOnboarding(model) }
    }
}

/// Start-up window when the data can't be opened (§11.9). Key missing: snapshots use the same key, so the path is
/// Restore from backup file (password). Any other failure (damaged database, failed migration…): the key is still
/// there, so the latest daily snapshot can come back too. Either way — or start fresh, or quit.
struct CantOpenView: View {
    enum Reason: Equatable {
        case keyMissing
        /// The error as `SafeError` describes it.
        case failed(String)
    }

    var reason: Reason = .keyMissing
    @State private var url: URL?
    @State private var password = ""
    @State private var error: String?
    @FocusState private var pwFocused: Bool
    private let latestSnapshot = SnapshotManager(directory: Paths.snapshots).list().first

    var body: some View {
        VStack(spacing: 14) {
            Illustration(name: "illLockedData", width: 320).padding(.top, 24)
            Text(reason == .keyMissing ? String(localized: "tikjot can't open your data") : String(localized: "tikjot couldn't start")).font(DS.F.screenTitle)
            Text(explanation)
                .font(DS.F.body).foregroundStyle(DS.C.text2).multilineTextAlignment(.center).frame(maxWidth: 480).fixedSize(horizontal: false, vertical: true)
            Well {
                VStack(spacing: 6) {
                    if case .failed(let detail) = reason { row(String(localized: "Problem"), detail) }
                    row(String(localized: "Your data"), "~/Library/Application Support/tikjot")
                    row(String(localized: "Daily snapshots"), snapshotRow)
                    row(String(localized: "Last backup file"), url?.lastPathComponent ?? String(localized: "choose the .tikjotbackup you exported"))
                }
            }
            .frame(maxWidth: 480)
            if url != nil {
                SecureField(String(localized: "Backup password"), text: $password).textFieldStyle(.plain).fieldStyle(focused: pwFocused)
                    .focused($pwFocused).onSubmit(restore).frame(maxWidth: 480)
            }
            if let error { Text(error).font(DS.F.caption).foregroundStyle(DS.C.dangerText) }
            Spacer(minLength: 0)
            HStack {
                Button(String(localized: "Start fresh…")) { startFresh() }.buttonStyle(LinkButtonStyle(color: DS.C.text3)).font(DS.F.caption)
                Spacer()
                Button(String(localized: "Quit")) { NSApp.terminate(nil) }.buttonStyle(.pill)
                if canRestoreSnapshot, url == nil {
                    Button(String(localized: "Restore from backup…")) { chooseFile() }.buttonStyle(.pill)
                    Button { restoreSnapshot() } label: {
                        Label(String(localized: "Restore snapshot"), systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        if url == nil || password.isEmpty { chooseFile() } else { restore() }
                    } label: {
                        Label(url != nil && !password.isEmpty ? String(localized: "Restore") : String(localized: "Restore from backup…"), systemImage: "externaldrive.badge.timemachine")
                    }
                    .buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 640, height: 600)
        .background(DS.C.surface)
    }

    /// Snapshots are sealed with the database key: only a failure other than a missing key can use them.
    private var canRestoreSnapshot: Bool { reason != .keyMissing && latestSnapshot != nil }

    private var explanation: String {
        switch reason {
        case .keyMissing:
            String(localized: "The key that unlocks your data isn't in this Mac's Keychain any more — usually after moving to a new Mac or resetting the Keychain. Nothing was deleted. Restore the backup file you exported: it brings back everything except Jira tokens.")
        case .failed where latestSnapshot != nil:
            String(localized: "Something went wrong while opening your data. Nothing was deleted. Go back to the latest daily snapshot, or restore the backup file you exported.")
        case .failed:
            String(localized: "Something went wrong while opening your data. Nothing was deleted. Restore the backup file you exported, or quit and try again later.")
        }
    }

    private var snapshotRow: String {
        guard reason != .keyMissing else { return String(localized: "need that key too") }
        guard let s = latestSnapshot else { return String(localized: "none yet") }
        return "\(Fmt.short(LocalDate(s.date, calendar: .current))) \(Fmt.time(s.date))"
    }

    /// The key is fine, the database isn't: set it aside and bring back the latest snapshot under the same key
    /// (so the older snapshots stay readable). Like a restore in Settings, read-only on the snapshot.
    private func restoreSnapshot() {
        guard let snap = latestSnapshot else { return }
        do {
            guard case .found(let key) = Keychain.lookup(Keychain.databaseKeyAccount) else { throw Keychain.Failure.unavailable(errSecItemNotFound) }
            let data = try AppDatabase.loadSnapshot(at: snap.url, key: key).validated()
            _ = moveOldAside()
            let db = try AppDatabase(url: Paths.database, key: key)
            try db.replaceAll(with: data)
            let model = try AppModel(db: db, connections: JiraConnections())
            AppDelegate.shared?.windows.closeRecovery()
            AppDelegate.shared?.start(with: model)
            model.showToast(String(localized: "Restored the snapshot from \(Fmt.short(LocalDate(snap.date, calendar: .current))) \(Fmt.time(snap.date))"))
        } catch Keychain.Failure.unavailable {
            error = Self.keychainUnavailable
        } catch {
            Log.error("snapshot restore at start failed: \(SafeError.describe(error))")
            self.error = String(localized: "Couldn't restore — \(SafeError.describe(error))")
        }
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a).font(DS.F.caption).foregroundStyle(DS.C.text2); Spacer(); Text(b).font(DS.F.body.monospacedDigit()).lineLimit(1) }
    }

    private func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.init(filenameExtension: "tikjotbackup") ?? .data]
        if p.runModal() == .OK, let u = p.url { url = u; error = nil; DispatchQueue.main.async { pwFocused = true } }
    }

    /// Moves the unreadable database aside and returns its stamp; any key still in the Keychain is kept
    /// under the same stamp (`database-key-<stamp>`) by `Keychain.newDatabaseKey`, so nothing becomes unrecoverable.
    private func moveOldAside() -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.setAside, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: Paths.database.path + suffix)
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: Paths.setAside.appendingPathComponent("tikjot-unreadable-\(stamp).sqlite\(suffix)"))
            }
        }
        return stamp
    }

    private func restore() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        do {
            let payload = try BackupCodec.import(data, password: password)
            // Check the Keychain answers before anything is moved.
            if case .failed(let s) = Keychain.lookup(Keychain.databaseKeyAccount) { throw Keychain.Failure.unavailable(s) }
            let key = try Keychain.newDatabaseKey(archivingAs: moveOldAside())
            let db = try AppDatabase(url: Paths.database, key: key)
            try db.replaceAll(with: payload.data)
            let model = try AppModel(db: db, connections: JiraConnections())
            // Like a restore in Settings: every connection needs its token again.
            model.forgetJiraTokens(Set(payload.data.instances.map(\.id)))
            AppDelegate.shared?.windows.closeRecovery()
            AppDelegate.shared?.start(with: model)
            AppDelegate.shared?.windows.showSettings(model, tab: .jira)
        } catch PersistenceError.backupWrongPassword {
            error = String(localized: "That password doesn't open this backup.")
        } catch PersistenceError.backupOutOfRange {
            error = Restore.outOfRangeMessage
        } catch Keychain.Failure.unavailable {
            error = Self.keychainUnavailable
        } catch {
            self.error = String(localized: "This file isn't a tikjot backup or is damaged.")
        }
    }

    private func startFresh() {
        let a = NSAlert()
        a.messageText = String(localized: "Start with empty data?")
        a.informativeText = String(localized: "The unreadable data is moved to a separate folder, not deleted. Whatever is in Jira comes back: connect Jira again and import your history.")
        a.addButton(withTitle: String(localized: "Start fresh"))
        a.addButton(withTitle: String(localized: "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // A locked or failing Keychain is not a missing key: don't move anything, ask to try again.
        if case .failed = Keychain.lookup(Keychain.databaseKeyAccount) { error = Self.keychainUnavailable; return }
        do {
            let key = try Keychain.newDatabaseKey(archivingAs: moveOldAside())
            let model = try AppModel(db: try AppDatabase(url: Paths.database, key: key), connections: JiraConnections())
            AppDelegate.shared?.windows.closeRecovery()
            AppDelegate.shared?.start(with: model)
        } catch Keychain.Failure.unavailable {
            error = Self.keychainUnavailable
        } catch {
            Log.error("start fresh failed: \(SafeError.describe(error))")
            self.error = SafeError.describe(error)
        }
    }

    private static var keychainUnavailable: String {
        String(localized: "The Keychain is locked or unavailable right now. Nothing was changed. Unlock your Mac's Keychain and try again.")
    }
}

struct RestoreSnapshotView: View {
    let date: Date
    let size: Int64
    let worklogs: Int
    let projects: Int
    let setAside: Int
    let done: (Bool) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Illustration(name: "illRestore", width: 320).padding(.top, 20)
            Text(String(localized: "Go back to \(Fmt.long(LocalDate(date, calendar: .current))), \(Fmt.time(date))?")).font(DS.F.screenTitle).multilineTextAlignment(.center)
            Text(String(localized: "tikjot will look exactly like it did then. Anything you tracked after that is kept aside in a separate file, so you can't lose it."))
                .font(DS.F.body).foregroundStyle(DS.C.text2).multilineTextAlignment(.center).frame(maxWidth: 460)
            Well {
                VStack(spacing: 6) {
                    row(String(localized: "Snapshot"), "\(Fmt.short(LocalDate(date, calendar: .current))) \(Fmt.time(date)) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                    row(String(localized: "Comes back"), String(localized: "\(worklogs) worklogs") + " · " + String(localized: "\(projects) projects"))
                    row(String(localized: "Set aside"), String(localized: "\(setAside) entries tracked after \(Fmt.time(date))"))
                }
            }
            .frame(maxWidth: 460)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { done(false) }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button { done(true) } label: { Label(String(localized: "Restore"), systemImage: "clock.arrow.circlepath") }.buttonStyle(.primaryPill).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640, height: 560)
        .background(DS.C.surface)
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a).font(DS.F.caption).foregroundStyle(DS.C.text2); Spacer(); Text(b).font(DS.F.body.monospacedDigit()) }
    }
}
