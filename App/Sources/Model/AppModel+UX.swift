import AppKit
import Foundation
import TikjotDomain
import TikjotPersistence

// Audit 2026-10-06, UX: one "needs you", undo names, the away prompt that survives a quit, in-app reminders and the
// backup nudge.

// MARK: Needs you (U1)

extension AppModel {
    /// Tasks Jira no longer accepts (deleted, no permission) — their unsent worklogs need you.
    /// Tasks Jira won't take: deleted, no permission, or on a site that was replaced (archived — it sends nothing).
    var unavailableIssues: Set<IssueRef> {
        let archived = Set(data.instances.filter { $0.status == .archived }.map(\.id))
        return Set(data.issues.filter { $0.availability != .ok || archived.contains($0.instanceId) }.map { IssueRef(instanceId: $0.instanceId, issueId: $0.issueId) })
    }

    /// Days that can still be sent: this month, plus the previous one while it is open.
    var sendWindow: DateRange {
        let start = lock.isLocked(today.firstOfMonth.adding(days: -1), today: today) ? today.firstOfMonth : today.firstOfMonth.adding(months: -1)
        return DateRange(start, today)
    }

    func needsYou(in range: DateRange) -> NeedsYou {
        ledger.needsYou(in: range, lock: lock, jiraConnected: jiraConnected, unavailable: unavailableIssues)
    }

    func needsYou(on d: LocalDate) -> NeedsYou {
        ledger.needsYou(on: d, lock: lock, jiraConnected: jiraConnected, unavailable: unavailableIssues)
    }

    /// Everything in the send window that needs you — the sidebar badge and Unsent's "Needs you" filter.
    var needsYouNow: NeedsYou { needsYou(in: sendWindow) }

    /// The Unsent badge (sidebar, popover footer, menu-bar dot): days not in Jira in the send window, brand when
    /// something needs you (variant V1, 2026-10-06).
    var unsentBadge: UnsentBadge {
        ledger.unsentBadge(in: sendWindow, lock: lock, jiraConnected: jiraConnected, unavailable: unavailableIssues)
    }
}

enum NeedsYouText {
    /// One day (popover header, Day panel chip): "1 entry needs you", "2 worklogs need you".
    static func items(_ n: NeedsYou) -> String? {
        switch (n.noTask, n.worklogs) {
        case (0, 0): return nil
        case (let e, 0): return String(localized: "\(e) entries need you")
        case (0, let w): return String(localized: "\(w) worklogs need you")
        default: return String(localized: "\(n.items) things need you")
        }
    }

    /// A period (Day/Week/Month toolbars, Statistics): "2 days need you".
    static func days(_ count: Int) -> String { String(localized: "\(count) days need you") }
}

// MARK: Undo names (U4)

extension UndoRecord {
    /// The menu's "Undo <name>" for what `perform` was called with; names with a value in them keep their kind.
    static func title(_ key: String) -> String {
        switch key {
        case "Start": return String(localized: "Start")
        case "Switch task": return String(localized: "Switch task")
        case "Stop": return String(localized: "Stop")
        case "Edit description": return String(localized: "Edit description")
        case "Change start": return String(localized: "Change start")
        case "Edit entry": return String(localized: "Edit entry")
        case "Change time": return String(localized: "Change time")
        case "Change task": return String(localized: "Change task")
        case "Delete": return String(localized: "Delete")
        case "Add entry": return String(localized: "Add entry")
        case "Mark as a break": return String(localized: "Mark as a break")
        case "Remove absence": return String(localized: "Remove absence")
        case "Edit absence": return String(localized: "Edit absence")
        case "New project": return String(localized: "New project")
        case "Edit project": return String(localized: "Edit project")
        case "Delete project": return String(localized: "Delete project")
        case "Merge": return String(localized: "Merge")
        case "Split": return String(localized: "Split")
        case "Trim": return String(localized: "Trim")
        case "Move after": return String(localized: "Move after")
        case "Move entry": return String(localized: "Move entry")
        case "Resize entry": return String(localized: "Resize entry")
        case "Extend entry": return String(localized: "Extend entry")
        case "Start entry earlier": return String(localized: "Start entry earlier")
        case "Edit comment": return String(localized: "Edit comment")
        case "Working hours": return String(localized: "Working hours")
        case "Change contract": return String(localized: "Change contract")
        case "Add company day": return String(localized: "Add company day")
        case "Remove company day": return String(localized: "Remove company day")
        case "Stop at when you left": return String(localized: "Stop at when you left")
        case "Cut away time": return String(localized: "Stop at when you left")
        case "Give away time to another task": return String(localized: "Give away time to another task")
        case "Remove time away": return String(localized: "Remove time away")
        default:
            if key.hasPrefix("New project") { return String(localized: "New project") }
            if key.hasPrefix("Merge ") { return String(localized: "Merge projects") }
            if key.hasPrefix("Give ") { return String(localized: "Change task") }
            if key.hasPrefix("Set ") { return String(localized: "Change time") }
            if key.hasPrefix("Add ") && key.hasSuffix(" to project") { return String(localized: "Add key to project") }
            if key.hasPrefix("Remove ") { return String(localized: "Remove key") }
            if key.hasPrefix("Add ") { return String(localized: "Add absence") }
            return key
        }
    }

    /// After ⌘Z: what came back ("Entry restored"), else what was undone.
    var undoneText: String {
        let restored = undo.upsertEntries.count
        switch key {
        case "Delete" where restored > 0: return String(localized: "\(restored) entries restored")
        case "Remove absence": return String(localized: "Absence restored")
        case "Delete project": return String(localized: "Project restored")
        default: return String(localized: "Undone: \(name)")
        }
    }
}

extension AppModel {
    var undoMenuTitle: String { undoStack.last.map { String(localized: "Undo \($0.name)") } ?? String(localized: "Undo") }
    var redoMenuTitle: String { redoStack.last.map { String(localized: "Redo \($0.name)") } ?? String(localized: "Redo") }

    /// The text view being edited in the key window, if any — ⌘Z belongs to it then.
    static var editingTextView: NSTextView? {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable else { return nil }
        return tv
    }

    /// ⌘Z: the text being typed first, tikjot's data otherwise.
    func undoFromMenu() {
        if let tv = Self.editingTextView {
            if tv.undoManager?.canUndo == true { tv.undoManager?.undo() }
            return
        }
        undo()
    }

    func redoFromMenu() {
        if let tv = Self.editingTextView {
            if tv.undoManager?.canRedo == true { tv.undoManager?.redo() }
            return
        }
        redo()
    }

    /// Text editing starts / ends anywhere in the app (field editors and text views post these).
    func observeTextEditing() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSText.didBeginEditingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.textEditing = true }
        }
        nc.addObserver(forName: NSText.didEndEditingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.textEditing = false }
        }
    }
}

// MARK: Away while the timer ran (U3)

extension AppModel {
    private static let awayKey = "tikjot.awayPrompt"

    /// The away prompt is kept until answered — also across a quit (it belongs to the entry that ran meanwhile).
    func persistAwayPrompt() {
        guard !demo else { return }
        if let p = awayPrompt {
            let v: [String: Any] = ["from": p.from.timeIntervalSince1970, "to": p.to.timeIntervalSince1970, "slept": p.slept, "entry": p.entryId.uuidString]
            UserDefaults.standard.set(v, forKey: Self.awayKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.awayKey)
        }
    }

    /// At launch: bring back an unanswered prompt while there's still something to answer.
    func restoreAwayPrompt() {
        guard !demo, awayPrompt == nil, let v = UserDefaults.standard.dictionary(forKey: Self.awayKey),
              let from = v["from"] as? Double, let to = v["to"] as? Double, let slept = v["slept"] as? Bool,
              let entry = (v["entry"] as? String).flatMap(UUID.init(uuidString:)) else {
            UserDefaults.standard.removeObject(forKey: Self.awayKey)
            return
        }
        let p = AwayPrompt(from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to), slept: slept, entryId: entry)
        if awayOwner(p) != nil { awayPrompt = p } else { UserDefaults.standard.removeObject(forKey: Self.awayKey) }
    }

    /// What the card is about (beta 2026-10-18: after a switch it used to act on the new timer — "Stop at" deleted
    /// it). The timer that ran while you were away, if it still runs (also continued past midnight); otherwise the
    /// finished entry that still holds the whole time away, on today. nil = nothing left to answer: it was deleted,
    /// its times were changed, or the day is over — the card goes away.
    func awayOwner(_ p: AwayPrompt) -> AwayOwner? {
        if let r = runningEntry, r.id == p.entryId || AwayOps.runningChain(r, entries: data.entries).contains(where: { $0.id == p.entryId }) {
            return .running(r)
        }
        guard LocalDate(p.from, calendar: timeCalendar) == today,
              let e = data.entries.first(where: { $0.id == p.entryId && $0.deletedAt == nil }),
              let end = e.end, e.start <= p.from, end >= p.to else { return nil }
        return .finished(e)
    }

    /// The card, when there's something to answer.
    var awayCard: (prompt: AwayPrompt, owner: AwayOwner)? {
        guard let p = awayPrompt, let o = awayOwner(p) else { return nil }
        return (p, o)
    }

    /// Clears a prompt that has nothing left to answer (BackgroundServices' tick).
    func dropStaleAwayPrompt() {
        if let p = awayPrompt, awayOwner(p) == nil { awayPrompt = nil }
    }

    /// "Stop at <time you left>" (timer still running) — or, after a switch, "Remove 45m" from the entry it was.
    func stopAtAway() {
        guard let p = awayPrompt, let owner = awayOwner(p) else { awayPrompt = nil; return }
        guard case .running(let r) = owner else {
            if case .finished(let e) = owner { removeAway(p, from: e) }
            return
        }
        pendingDescription = nil
        let ch = AwayOps.stop(at: p.from, running: r, entries: data.entries)
        var c = Changes()
        c.upsertEntries = ch.updated
        c.deleteEntries = ch.deleted.map(\.id)
        awayPrompt = nil
        perform("Stop at when you left", c, toast: String(localized: "Stopped at \(Fmt.time(p.from))"))
        Sounds.play(.stop, enabled: data.settings.soundsEnabled)
    }

    /// The time away taken out of a finished entry (it's split around it). The running timer isn't touched.
    private func removeAway(_ p: AwayPrompt, from e: TimeEntry) {
        guard let ch = try? EntryOps.carve(e, from: p.from, to: p.to) else { awayPrompt = nil; return }
        var c = Changes()
        c.upsertEntries = ch.updated + ch.inserted
        c.deleteEntries = ch.deleted.map(\.id)
        awayPrompt = nil
        perform("Remove time away", c, toast: String(localized: "Removed \(DurationFormat.hm(p.seconds)) from \(awayTaskName(e))"))
    }

    /// The task the card names after a switch: its key, else the project, else the description.
    func awayTaskName(_ e: TimeEntry) -> String {
        if let i = issue(for: e) { return i.key }
        if let pr = project(e.projectId) { return pr.name }
        return e.description.isEmpty ? String(localized: "No task") : e.description
    }

    /// Notification button "Cut it" — the same answer as the card's primary button.
    func cutAway() { stopAtAway() }

    /// Keep it as it is — the time away counts (also the card's ×).
    func keepAway() { awayPrompt = nil }

    /// Settings › Tracking › "Mac slept with a timer running" switch (kept on this Mac, like the other reminder marks).
    var sleepPromptEnabled: Bool {
        get { _ = localPrefsStamp; return UserDefaults.standard.object(forKey: "tikjot.sleepPromptEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tikjot.sleepPromptEnabled"); localPrefsStamp += 1 }
    }
}

// MARK: Last backup export (shown in Settings › Backup; no reminders — decided 2026-10-06)

extension AppModel {
    private static let exportedKey = "tikjot.backup.lastExported"

    var lastBackupExport: Date? {
        get { _ = localPrefsStamp; return UserDefaults.standard.object(forKey: Self.exportedKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.exportedKey); localPrefsStamp += 1 }
    }
}
