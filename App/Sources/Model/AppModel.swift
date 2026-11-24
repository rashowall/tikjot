import Foundation
import JiraKit
import Observation
import SwiftUI
import SyncEngine
import TikjotDomain
import TikjotHolidays
import TikjotPersistence
import TikjotSuggestions

/// One undoable step (⌘Z / ⇧⌘Z, toasts with Undo).
struct UndoRecord {
    /// What the menu says: "Undo <name>" / "Redo <name>" (localized, AppModel+UX).
    let name: String
    let undo: Changes
    let redo: Changes
    /// The action as `perform` named it (decides the "what came back" toast).
    var key = ""
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var undoable = false
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
    var progress: String?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id && a.text == b.text && a.progress == b.progress }
}

/// The app's state and every local mutation. Lives on the main actor; Jira work goes through `SyncEngine`.
@MainActor
@Observable
final class AppModel {
    let db: AppDatabase
    let demo: Bool
    private(set) var data: DataSnapshot { didSet { dataRevision &+= 1 } }
    /// Every change of `data` (any path), for caches of what is computed from it.
    @ObservationIgnored private(set) var dataRevision = 0
    /// The task picker's scoring of every task against your entries, kept until the data or the minute changes
    /// (beta 2026-10-22: typing in the task search lagged seconds — the picker re-scored all tasks many times a key).
    @ObservationIgnored private var scoredCache: (base: String, byArchived: [Set<String>: [SuggestionEngine.Candidate]]) = ("", [:])
    /// Bumped on every data change (cheap view invalidation key).
    private(set) var version = 0
    /// Updated every few seconds so live numbers move.
    var now = Clock.now

    var toast: Toast?
    var undoStack: [UndoRecord] = []
    var redoStack: [UndoRecord] = []

    // Jira state
    var offline = false
    var refreshing: (done: Int, total: Int)?
    /// When the last refresh began (any reason) — the picker's refreshIfStale reads it.
    var lastRefreshStarted = Date.distantPast
    var lastRefreshError: JiraError?
    var sendInProgress = false
    var lastSendReport: SendReport?
    var rateLimitedFor: TimeInterval?
    /// Jira project keys found in worklogs without a project (first-run proposals, §10.4): key → (Jira project name,
    /// instance). Saved on every change, so a restart doesn't lose them.
    var pendingProjectSuggestions: [String: (String, UUID)] = [:] {
        didSet { savePendingProjectSuggestions() }
    }

    // Navigation requests from the popover / notifications to the main window
    var mainSelection: MainSection = .day
    var selectedDay: LocalDate
    var selectedEntryIds: Set<UUID> = []
    var reviewRequest: ReviewRequest?
    var settingsTab: SettingsTab = .general
    /// What the popover has brought forward (the rest fades to 28 %).
    var popoverEditing: PopoverEditing?
    var popoverOpenedAt = Clock.now
    /// Bumped by ⌥⌘T / Start a timer while idle: the capsule focuses "What are you working on?" and shows your
    /// recent work (type first; the task field is Tab away).
    var descriptionFocusRequest = 0

    /// Idle start from anywhere: the popover's description field with its suggestions, not the task picker.
    func focusTimerDescription() {
        popoverEditing = nil
        descriptionFocusRequest += 1
    }
    /// Sleep / away while the timer ran (§7.2, §11.9) — asked on wake; kept across quits (AppModel+UX).
    var awayPrompt: AwayPrompt? { didSet { persistAwayPrompt() } }
    /// A text field or editor is being typed in: ⌘Z / ⇧⌘Z go to its text undo (audit U4).
    var textEditing = false
    /// View menu / Help menu requests to the main window (audit U9).
    var showCommandBar = false
    var showShortcuts = false
    /// Settings › Jira opens the "new token" band under this site (Renew in a token-expiry banner or notification).
    var renewTokenRequest: UUID?
    /// Bumped when a per-Mac preference in UserDefaults changes (backup export date, nudge, sleep prompt switch).
    var localPrefsStamp = 0
    /// Monday check (§11.11): last week's empty workdays.
    var mondayHoles: [LocalDate] = []
    var snapshotError: String?
    /// Prefill for the absence form (Monday check, Month row, "Add absence" on a day).
    var absenceDraftDays: [LocalDate] = []
    var lastWake: Date?
    var unsentFilterNeedsYou = false
    var monthFilterNeedsYou = false
    var dismissedTimeZoneWarning = false
    /// A full menu bar hides tikjot's icon (MenuBarController checks where it ended up).
    var menuBarHidden = false
    var dismissedMenuBarHint = false
    var splitRequest: UUID?
    var inspectorPickTask = false
    var exportRequest = false
    var projectsSelection: UUID?

    @ObservationIgnored let connections: JiraConnections
    @ObservationIgnored lazy var engine: SyncEngine = SyncEngine(store: SyncBridge(model: self), clientFor: { [connections] id in await connections.client(for: id) })
    @ObservationIgnored private var cachedLedger: (version: Int, minute: Int, ledger: Ledger)?
    /// While Jira can't be reached: the next try (10 s, 30 s, 1, 2, 5, 10, then every 15 min) — not the next auto refresh.
    @ObservationIgnored var offlineRetry: Task<Void, Never>?
    /// The network changed while a Jira was unreachable: one try once it settles (debounced, at most every 10 s).
    @ObservationIgnored var networkRetry: Task<Void, Never>?
    /// Connections that didn't answer last time (VPN off, company sign-in page). `offline` is "this set isn't
    /// empty"; retries ask only these, so a working connection isn't fetched again and again.
    @ObservationIgnored var unreachableInstances: Set<UUID> = []
    /// Whether you're away from the Mac (no input for 2 min, screen locked) — set by BackgroundServices. While away,
    /// an unreachable Jira isn't retried (beta 2026-10-15: a Data Center Jira was asked all night); the try waits.
    @ObservationIgnored var userAway: () -> Bool = { false }
    @ObservationIgnored var jiraWaitsForYou = false
    @ObservationIgnored private var holidayCache: (key: String, holidays: [Holiday])?
    @ObservationIgnored var onDataChange: [@MainActor () -> Void] = []
    @ObservationIgnored var lastIssueRefresh: [UUID: Date] = [:]

    var timeCalendar: Calendar { .gregorianCurrent }

    init(db: AppDatabase, demo: Bool = false, connections: JiraConnections) throws {
        self.db = db
        self.demo = demo
        self.connections = connections
        self.data = try db.load()
        self.selectedDay = LocalDate(Clock.now, calendar: .current)
        connections.model = self
        seedDefaults()
        reconcile()
        loadPendingProjectSuggestions()
    }

    static func builtinName(_ b: BuiltinAbsence) -> String {
        switch b {
        case .vacation: return String(localized: "Vacation")
        case .doctor: return String(localized: "Doctor")
        case .sickLeave: return String(localized: "Sick leave")
        case .childCare: return String(localized: "Child care")
        }
    }

    // MARK: Derived state

    var settings: AppSettings { data.settings }
    var lock: LockPolicy { LockPolicy(graceDays: data.settings.graceDays) }
    var today: LocalDate { LocalDate(now, calendar: timeCalendar) }
    var schedule: WorkSchedule { data.schedule.isEmpty ? .standard : WorkSchedule(periods: data.schedule) }
    var runningEntry: TimeEntry? { data.entries.last { $0.end == nil && $0.deletedAt == nil } }
    var activeInstances: [JiraInstance] { data.instances.filter { $0.status != .archived && $0.deletedAt == nil } }
    var jiraConnected: Bool { !activeInstances.isEmpty }
    var signedOutInstances: [JiraInstance] { activeInstances.filter { $0.status == .authError } }

    var language: String {
        switch data.settings.language {
        case "sk": return "sk"
        case "en": return "en"
        default: return Locale.preferredLanguages.first?.hasPrefix("sk") == true ? "sk" : "en"
        }
    }

    var holidays: [Holiday] {
        let first = data.entries.first.map { LocalDate($0.start, calendar: timeCalendar).year } ?? today.year
        let key = "\(data.settings.holidayCountry)|\(min(first, today.year - 1))|\(today.year + 1)|\(language)"
        if let h = holidayCache, h.key == key { return h.holidays }
        let h = HolidayEngine.holidays(country: data.settings.holidayCountry, years: min(first, today.year - 1)...(today.year + 1), language: language)
        holidayCache = (key, h)
        return h
    }

    var dayCalendar: DayCalendar {
        DayCalendar(schedule: schedule, holidays: holidays, customDays: data.customDays, absences: data.absences)
    }

    /// The ledger for "now"; cached per data version and minute.
    var ledger: Ledger {
        let minute = Int(now.timeIntervalSince1970 / 60)
        if let c = cachedLedger, c.version == version, c.minute == minute { return c.ledger }
        let l = Ledger(entries: data.entries, groups: data.groups, projects: data.projects, calendar: dayCalendar,
                       rounding: data.settings.rounding, timeCalendar: timeCalendar, now: now, knownFrom: dataStart)
        cachedLedger = (version, minute, l)
        return l
    }

    func project(_ id: UUID?) -> Project? { id.flatMap { pid in data.projects.first { $0.id == pid } } }

    func issue(_ ref: IssueRef?) -> Issue? {
        guard let ref else { return nil }
        return data.issues.first { $0.instanceId == ref.instanceId && $0.issueId == ref.issueId }
    }

    func issue(for e: TimeEntry) -> Issue? { issue(e.issueRef) }

    /// The issue's page on its own Jira site (an archived on-prem task opens the old site); nil without a task.
    func jiraURL(_ ref: IssueRef?) -> URL? {
        guard let i = issue(ref), let inst = data.instances.first(where: { $0.id == i.instanceId }) else { return nil }
        return inst.baseURL.appendingPathComponent("browse/\(i.key)")
    }

    /// "Open in Jira" (beta 2026-10-25): the browser shows it if Jira can't be reached, tikjot shows no error.
    func openInJira(_ ref: IssueRef?) {
        if let u = jiraURL(ref) { NSWorkspace.shared.open(u) }
    }

    /// Project for a Jira issue via key rules (§6.3).
    func projectId(for issue: Issue) -> UUID? {
        data.rules.first { $0.instanceId == issue.instanceId && $0.value == issue.projectKey }?.projectId
    }

    /// Project for an issue; a Jira key that no project covers gets its own new project, named after the
    /// Jira project (auto colour, billable) — never blocks starting a timer. A quiet toast offers to change it.
    @discardableResult
    func ensureProject(for issue: Issue) -> UUID {
        if let p = projectId(for: issue) { return p }
        let key = issue.projectKey
        let cached = data.issues.first { $0.instanceId == issue.instanceId && $0.issueId == issue.issueId }
        let name = (issue.projectName ?? cached?.projectName).flatMap { $0.isEmpty ? nil : $0 } ?? key
        let p = Project(name: name, color: ProjectPalette.nextUnused(data.projects.map(\.color)), billable: true)
        var c = Changes()
        c.upsertProjects = [p]
        c.upsertRules = [ProjectRule(projectId: p.id, instanceId: issue.instanceId, value: key)]
        c.upsertEntries = refiledEntries(for: [(issue.instanceId, key)], to: p.id)
        perform("New project \(name)", c)
        showToast(String(localized: "\(key) → new project \(name)"), actionTitle: String(localized: "Change")) { [weak self] in
            guard let self else { return }
            self.projectsSelection = p.id
            self.mainSelection = .projects
            MenuBarController.shared?.closePopover()
            AppDelegate.shared?.windows.showMain(self)
        }
        return p.id
    }

    func absenceType(_ id: UUID) -> AbsenceType? { data.absenceTypes.first { $0.id == id } }

    func absences(on d: LocalDate) -> [Absence] { data.absences.filter { $0.date == d && $0.deletedAt == nil } }

    var balanceRange: DateRange {
        switch data.settings.balancePeriod {
        case .week: return DateRange.week(of: today)
        case .month: return DateRange.month(of: today)
        case .quarter: return DateRange(today.firstOfQuarter, today.firstOfQuarter.adding(months: 3).adding(days: -1))
        }
    }

    /// The first day tikjot knows about: opening balance date, imported history start or the first entry.
    /// Year-to-date numbers never count fund before it (a mid-year start would otherwise show a huge deficit).
    var dataStart: LocalDate {
        BalanceStart.dataStart(opening: data.settings.openingBalance, historyStarts: data.instances.compactMap(\.historyStartDate),
                               firstEntry: data.entries.first.map { LocalDate($0.start, calendar: timeCalendar) }, today: today)
    }

    var cumulativeStart: LocalDate { BalanceStart.effective(configured: data.settings.cumulativeStart, dataStart: dataStart, today: today) }

    /// Year window for utilization, starting no earlier than `dataStart`.
    var yearRange: DateRange { DateRange(max(today.firstOfYear, min(dataStart, today)), today) }

    // MARK: Writing

    /// Applies changes, reconciles worklog groups and records undo.
    func perform(_ name: String, _ changes: Changes, undoable: Bool = true, toast toastText: String? = nil) {
        guard !changes.isEmpty else { return }
        let inverse = data.inverse(of: changes)
        do {
            try db.apply(changes)
            data.apply(changes)
        } catch {
            Log.error("write failed: \(SafeError.describe(error))")
            showToast(String(localized: "Couldn't save — \(SafeError.describe(error))"))
            return
        }
        if undoable {
            undoStack.append(UndoRecord(name: UndoRecord.title(name), undo: inverse, redo: changes, key: name))
            if undoStack.count > 100 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        reconcile()
        if let toastText { showToast(toastText, undoable: undoable) }
    }

    /// Writes that aren't user edits (sync results, settings) — no undo.
    func applySilently(_ changes: Changes) {
        guard !changes.isEmpty else { return }
        do {
            try db.apply(changes)
            data.apply(changes)
        } catch {
            Log.error("write failed: \(SafeError.describe(error))")
        }
        reconcile()
    }

    func reconcile() {
        // After a Data Center → Cloud link, projects and never-sent work follow their keys (beta 2026-11-16).
        let followed = SuccessionHeal.changes(data)
        if !followed.isEmpty {
            try? db.apply(followed)
            data.apply(followed)
            Log.info("succession heal: \(followed.deleteProjects.count) projects merged, \(followed.upsertRules.count) keys, \(followed.deleteRules.count) dead keys, \(followed.upsertEntries.count) entries")
        }
        let r = Reconciler.reconcile(data, calendar: timeCalendar, lock: lock, today: today, now: now)
        if !r.isEmpty {
            try? db.apply(r)
            data.apply(r)
        }
        version += 1
        // A failed update with nothing left to send is in Jira after all (beta 2026-10-25, decision #130).
        let healed = ledger.failedButInJira(lock: lock)
        if !healed.isEmpty {
            var c = Changes()
            c.upsertGroups = healed
            try? db.apply(c)
            data.apply(c)
            Log.info("failed updates already in Jira: \(healed.count)")
            version += 1
        }
        for f in onDataChange { f() }
    }

    /// First-launch defaults (also after "Delete all data"): a work schedule and the built-in absence types,
    /// named in the app language.
    func seedDefaults() {
        var c = Changes()
        if data.schedule.isEmpty { c.upsertSchedule = [WorkSchedulePeriod(effectiveFrom: LocalDate(year: 2000, month: 1, day: 1))] }
        let missingTypes = AbsenceType.builtins.filter { b in !data.absenceTypes.contains { $0.id == b.id } }
        if !missingTypes.isEmpty { c.upsertAbsenceTypes = missingTypes }
        for var t in data.absenceTypes + missingTypes {
            guard let b = t.builtin else { continue }
            let name = AppModel.builtinName(b)
            if t.name != name { t.name = name; c.upsertAbsenceTypes.removeAll { $0.id == t.id }; c.upsertAbsenceTypes.append(t) }
        }
        guard !c.isEmpty else { return }
        do {
            try db.apply(c)
            data.apply(c)
        } catch {
            Log.error("write failed: \(SafeError.describe(error))")
        }
    }

    /// Reloads everything from the database (after a restore).
    func reloadFromDatabase() {
        if let d = try? db.load() { data = d }
        seedDefaults()
        undoStack.removeAll()
        redoStack.removeAll()
        reconcile()
        applyAppearance()
    }

    /// Undoes the last data change; the toast says what came back and offers Redo (audit U4).
    func undo() {
        guard let r = undoStack.popLast() else { return }
        try? db.apply(r.undo)
        data.apply(r.undo)
        redoStack.append(r)
        reconcile()
        showToast(r.undoneText, actionTitle: String(localized: "Redo")) { [weak self] in self?.redo() }
    }

    func redo() {
        guard let r = redoStack.popLast() else { return }
        try? db.apply(r.redo)
        data.apply(r.redo)
        undoStack.append(r)
        reconcile()
        showToast(String(localized: "Redone: \(r.name)"), undoable: true)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func updateSettings(_ f: (inout AppSettings) -> Void) {
        var s = data.settings
        f(&s)
        var c = Changes()
        c.settings = s
        applySilently(c)
        applyAppearance()
    }

    /// Settings › General › Appearance: System / Light / Dark (windows, popover and sheets).
    func applyAppearance() {
        switch data.settings.appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }

    func showToast(_ text: String, undoable: Bool = false, actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        let t = Toast(text: text, undoable: undoable, actionTitle: actionTitle, action: action)
        toast = t
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if self.toast?.id == t.id { self.toast = nil }
        }
    }

    // MARK: Timer (§7.1)

    /// Starts tracking. A running timer stops at the same instant.
    func start(issue: Issue? = nil, projectId: UUID? = nil, description: String = "", at start: Date? = nil) {
        let instant = (start ?? now).roundedToSecond
        let pid = projectId ?? issue.map { ensureProject(for: $0) }
        let e = TimeEntry(start: instant, end: nil, instanceId: issue?.instanceId, issueId: issue?.issueId,
                          projectId: pid, description: description)
        let running = runningEntry
        var c = Changes()
        let ch = EntryOps.start(e, running: running, at: instant)
        c.upsertEntries = ch.inserted + ch.updated
        c.deleteEntries = ch.deleted.map(\.id)
        perform(running == nil ? "Start" : "Switch task", c)
        if let issue { touchIssue(issue) }
        Sounds.play(.start, enabled: data.settings.soundsEnabled)
    }

    /// A description being typed in the popover for the running entry (not saved yet). Any stop — the popover,
    /// ⌥⌘S, the widget, the main window — keeps it.
    var pendingDescription: (entryId: UUID, text: String)?

    func stop(at instant: Date? = nil) {
        if let p = pendingDescription, var cur = runningEntry, cur.id == p.entryId, cur.description != p.text {
            cur.description = p.text
            update(cur, name: "Edit description")
        }
        pendingDescription = nil
        guard let r = runningEntry else { return }
        let at = (instant ?? now).roundedToSecond
        var c = Changes()
        let parts = EntryOps.stop(r, at: at)
        if parts.discarded {
            c.deleteEntries = [r.id]
            perform("Stop", c, toast: String(localized: "Under a minute — not kept"))
            return
        }
        // Split at midnight when it ran across (§7.1).
        var stopped = parts.change.updated[0]
        let mid = EntryOps.normalizeMidnight(stopped, calendar: timeCalendar)
        if !mid.isEmpty { stopped = mid.updated[0] }
        c.upsertEntries = [stopped] + mid.inserted
        Sounds.play(.stop, enabled: data.settings.soundsEnabled)
        perform("Stop", c, toast: String(localized: "Stopped · \(DurationFormat.hm(Int(at.timeIntervalSince(r.start))))"))
    }

    /// Continue: same task, project and description, starting now (§7.3).
    func continueEntry(_ e: TimeEntry, newDescription: Bool = false) {
        start(issue: issue(for: e), projectId: e.projectId, description: newDescription ? "" : e.description)
    }

    func toggleTimer() {
        if runningEntry != nil { stop() } else if let last = data.entries.last(where: { $0.end != nil && $0.kind == .work }) { continueEntry(last) }
    }

    /// A timer running across midnight is split at 00:00 into two days (§7.1).
    func splitRunningAtMidnight() {
        guard let r = runningEntry else { return }
        let parts = AwayOps.splitRunning(r, today: today, calendar: timeCalendar)
        guard !parts.isEmpty else { return }
        var c = Changes()
        c.upsertEntries = parts
        applySilently(c)
    }

    /// Change the running entry's start (popover start-time panel).
    func setRunningStart(_ d: Date) {
        guard var r = runningEntry else { return }
        r.start = min(d, now).roundedToSecond
        r.updatedAt = Clock.now
        var c = Changes()
        c.upsertEntries = [r]
        perform("Change start", c)
    }

    // MARK: Entries (§7.3)

    func update(_ e: TimeEntry, name: String = "Edit entry") {
        var x = e
        x.updatedAt = Clock.now
        var c = Changes()
        if let end = x.end {
            // An imported worklog is one worklog in Jira: editing it keeps it whole (Ledger counts it on its first day).
            let mid = x.source == .imported ? EntryChange() : EntryOps.normalizeMidnight(x, calendar: timeCalendar)
            if !mid.isEmpty { x = mid.updated[0]; c.upsertEntries = mid.inserted }
            if end <= x.start { return }
        }
        c.upsertEntries.insert(x, at: 0)
        perform(name, c)
    }

    func setTask(_ issue: Issue?, projectId: UUID?, for entries: [TimeEntry]) {
        var c = Changes()
        for var e in entries {
            e.instanceId = issue?.instanceId
            e.issueId = issue?.issueId
            // A task brings its project; without a task the picker's choice is explicit (nil = no project).
            e.projectId = issue.map { projectId ?? ensureProject(for: $0) } ?? projectId
            if e.source == .imported && issue != nil { e.source = .local; e.worklogGroupId = nil }
            e.updatedAt = Clock.now
            c.upsertEntries.append(e)
        }
        perform(entries.count > 1 ? "Give \(entries.count) entries one task" : "Change task", c)
        if let issue { touchIssue(issue) }
    }

    func delete(_ entries: [TimeEntry]) {
        var c = Changes()
        c.deleteEntries = entries.map(\.id)
        perform("Delete", c, toast: entries.count > 1 ? String(localized: "Entries deleted: \(entries.count)") : String(localized: "Entry deleted"))
        selectedEntryIds.subtract(entries.map(\.id))
    }

    func apply(_ ch: EntryChange, name: String, toast: String? = nil) {
        var c = Changes()
        c.upsertEntries = ch.inserted + ch.updated
        c.deleteEntries = ch.deleted.map(\.id)
        perform(name, c, toast: toast)
    }

    @discardableResult
    func addEntry(on day: LocalDate, from: Date? = nil, to: Date? = nil, issue: Issue? = nil, projectId: UUID? = nil, description: String = "") -> TimeEntry? {
        guard lock.canEditEntries(on: day, today: today) else { return nil }
        let p = schedule.period(on: day)
        let (s, e) = from.flatMap { f in to.map { (f, $0) } } ?? EntryOps.placementForNewEntry(on: day, entries: ledger.entries(on: day), workdayStartMinutes: p.workdayStart, now: now, calendar: timeCalendar)
        let entry = TimeEntry(start: s, end: min(e, max(s.addingTimeInterval(60), day == today ? max(now, s.addingTimeInterval(60)) : e)),
                              instanceId: issue?.instanceId, issueId: issue?.issueId,
                              projectId: projectId ?? issue.map { ensureProject(for: $0) }, description: description)
        var c = Changes()
        c.upsertEntries = [entry]
        perform("Add entry", c)
        selectedEntryIds = [entry.id]
        return entry
    }

    /// Mark a gap as a break (§11.11): quiet row, doesn't count.
    func markBreak(from: Date, to: Date) {
        let e = TimeEntry(start: from, end: to, description: "Lunch break", kind: .breakTime)
        var c = Changes()
        c.upsertEntries = [e]
        perform("Mark as a break", c, toast: String(localized: "Marked as a break · doesn't count"))
    }

    /// The project a "No task yet" pick keeps: the running entry's, if any — never one guessed from history
    /// (beta 2026-10-08, row 13: no task = no guessed project; it used to take the last *inserted* entry's project,
    /// even an old import). Starting or adding an entry without a task files it in no project unless one was picked.
    var defaultProjectId: UUID? { runningEntry?.projectId }

    // MARK: Absences (§6.9)

    func addAbsence(type: AbsenceType, days: [LocalDate], unit: AbsenceUnit, seconds: Seconds = 0, startMinutes: Int? = nil, note: String = "") {
        let range = days.count > 1 ? UUID() : nil
        var c = Changes()
        let cal = dayCalendar
        for d in days {
            // Ranges count working days only; holidays inside are reported, not stored.
            if days.count > 1 && !cal.isWorkday(d) { continue }
            c.upsertAbsences.append(Absence(typeId: type.id, date: d, unit: unit, amountSeconds: seconds, startMinutes: startMinutes, note: note, rangeId: range))
        }
        perform("Add \(type.name.lowercased())", c, toast: String(localized: "\(type.name) added"))
    }

    func removeAbsences(_ list: [Absence]) {
        var c = Changes()
        c.deleteAbsences = list.map(\.id)
        perform("Remove absence", c, toast: String(localized: "Absence removed"))
    }

    func updateAbsence(_ a: Absence) {
        var c = Changes()
        var x = a
        x.updatedAt = Clock.now
        c.upsertAbsences = [x]
        perform("Edit absence", c)
    }

    // MARK: Projects (§10.4)

    @discardableResult
    func createProject(name: String, color: String? = nil, billable: Bool = true, excludeFromWorked: Bool = false, keys: [(UUID, String)] = []) -> Project {
        let p = Project(name: name, color: color ?? ProjectPalette.nextUnused(data.projects.map(\.color)), billable: billable, excludeFromWorked: excludeFromWorked)
        var c = Changes()
        c.upsertProjects = [p]
        c.upsertRules = keys.map { ProjectRule(projectId: p.id, instanceId: $0.0, value: $0.1) }
        c.upsertEntries = refiledEntries(for: keys, to: p.id)
        perform("New project", c)
        return p
    }

    func updateProject(_ p: Project) {
        var c = Changes()
        var x = p
        x.updatedAt = Clock.now
        c.upsertProjects = [x]
        perform("Edit project", c)
    }

    /// Adds a Jira key to a project (moving it from another project if needed) and re-files entries.
    func assignKey(_ key: String, instanceId: UUID, to projectId: UUID) {
        var c = Changes()
        c.upsertRules = [ProjectRule(projectId: projectId, instanceId: instanceId, value: key)]
        c.upsertEntries = refiledEntries(for: [(instanceId, key)], to: projectId)
        perform("Add \(key) to project", c)
    }

    func removeKey(_ rule: ProjectRule) {
        var c = Changes()
        c.deleteRules = [rule.id]
        perform("Remove \(rule.value)", c)
    }

    private func refiledEntries(for keys: [(UUID, String)], to projectId: UUID) -> [TimeEntry] {
        let keySet = Set(keys.map { "\($0.0.uuidString)|\($0.1.uppercased())" })
        return data.entries.compactMap { e in
            guard let i = issue(for: e), keySet.contains("\(i.instanceId.uuidString)|\(i.projectKey)"), e.projectId != projectId,
                  !lock.isLocked(LocalDate(e.start, calendar: timeCalendar), today: today) else { return nil }
            var x = e
            x.projectId = projectId
            return x
        }
    }

    /// Merge `from` into `into`: keys and entries move, `from` is deleted (§10.4).
    func mergeProject(_ from: Project, into: Project) {
        var c = Changes()
        c.upsertRules = data.rules.filter { $0.projectId == from.id }.map { var r = $0; r.projectId = into.id; return r }
        c.upsertEntries = data.entries.filter { $0.projectId == from.id }.map { var e = $0; e.projectId = into.id; return e }
        c.deleteProjects = [from.id]
        perform("Merge \(from.name) into \(into.name)", c, toast: String(localized: "\(from.name) merged into \(into.name)"))
    }

    func deleteProject(_ p: Project) {
        guard !data.entries.contains(where: { $0.projectId == p.id }) else { return }
        var c = Changes()
        c.deleteProjects = [p.id]
        c.deleteRules = data.rules.filter { $0.projectId == p.id }.map(\.id)
        perform("Delete project", c)
    }

    // MARK: Issues

    func touchIssue(_ i: Issue) {
        guard !data.issues.contains(where: { $0.instanceId == i.instanceId && $0.issueId == i.issueId }) else { return }
        var c = Changes()
        c.upsertIssues = [i]
        applySilently(c)
    }

    func togglePin(_ i: Issue) {
        var x = data.issues.first { $0.id == i.id } ?? i
        x.pinned.toggle()
        x.pinOrder = (data.issues.filter(\.pinned).map(\.pinOrder).max() ?? 0) + 1
        var c = Changes()
        c.upsertIssues = [x]
        applySilently(c)
    }

    // MARK: Suggestions (§10.1)

    func suggestions(limit: Int = 10) -> [SuggestionEngine.Candidate] {
        SuggestionEngine().top(scoredIssues(archived: archivedKeys), limit: limit)
    }

    /// "What are you working on?" suggestions: your earlier description + task combinations (Toggl pattern).
    func descriptionSuggestions(_ q: String, limit: Int = 5) -> [DescriptionSuggestions.Suggestion] {
        DescriptionSuggestions.suggest(entries: Array(data.entries.suffix(4000)), issues: data.issues, query: q, now: now, limit: limit)
    }

    func issue(instanceId: UUID?, issueId: String?) -> Issue? {
        guard let instanceId, let issueId else { return nil }
        return data.issues.first { $0.instanceId == instanceId && $0.issueId == issueId }
    }

    func searchLocal(_ q: String) -> [SuggestionEngine.Candidate] {
        SuggestionEngine().search(q, candidates: scoredIssues(), projectNames: projectNamesByKey)
    }

    /// The picker's ranked sections for a typed query: you logged › assigned to you › more in Jira (§10.2).
    func rankTasks(_ q: String, remote: [Issue]) -> SuggestionEngine.Ranked {
        let active = remote.filter { i in activeInstances.contains { $0.id == i.instanceId } }
        return SuggestionEngine().rank(q, candidates: scoredIssues(), remote: active, projectNames: projectNamesByKey)
    }

    /// Tasks used before with descriptions like `description` (task step after a new description).
    func tasksUsed(withSimilarTo description: String, limit: Int = 3) -> [SuggestionEngine.Candidate] {
        SuggestionEngine().similar(to: description, candidates: scoredIssues(archived: archivedKeys),
                                   entries: Array(data.entries.suffix(3000)), limit: limit)
    }

    private func scoredIssues(archived: Set<String> = []) -> [SuggestionEngine.Candidate] {
        let base = "\(dataRevision)|\(Int(now.timeIntervalSince1970 / 60))|\(activeInstances.map(\.id))"
        if scoredCache.base != base { scoredCache = (base, [:]) }
        if let v = scoredCache.byArchived[archived] { return v }
        let v = SuggestionEngine().score(issues: data.issues.filter { i in activeInstances.contains { $0.id == i.instanceId } },
                                         entries: Array(data.entries.suffix(3000)), archivedProjectKeys: archived, now: now, calendar: timeCalendar)
        scoredCache.byArchived[archived] = v
        return v
    }

    private var projectNamesByKey: [String: String] {
        var names: [String: String] = [:]
        for r in data.rules { names[r.value] = project(r.projectId)?.name }
        return names
    }

    var archivedKeys: Set<String> {
        let archived = Set(data.projects.filter(\.archived).map(\.id))
        return Set(data.rules.filter { archived.contains($0.projectId) }.map { "\($0.instanceId.uuidString)|\($0.value)" })
    }

    /// Recent descriptions without a task (picker "No task yet" history).
    func lastDescription(for issue: Issue) -> String? {
        data.entries.last { $0.instanceId == issue.instanceId && $0.issueId == issue.issueId && !$0.description.isEmpty }?.description
    }

    // MARK: Sync context

    func syncContext() -> SyncContext {
        SyncContext(data: data, ledger: ledger, lock: lock, calendar: timeCalendar)
    }
}

enum MainSection: String, CaseIterable, Identifiable {
    case day, week, month, unsent, statistics, projects
    var id: String { rawValue }
}

struct ReviewRequest: Identifiable, Equatable {
    let id = UUID()
    var scope: ReviewScope
    var title: String
    /// What is being sent, on its own ("today", "Week 41", "October") — results say "<name> is in Jira" without
    /// taking the title apart (audit U10). nil: a selection of worklogs.
    var name: String?
}

/// Lets the (non-isolated) sync engine read and write the main-actor model.
final class SyncBridge: SyncStore {
    let model: AppModel
    init(model: AppModel) { self.model = model }

    func context() async -> SyncContext {
        await MainActor.run { model.syncContext() }
    }

    func apply(_ changes: Changes) async throws {
        await MainActor.run { model.applySilently(changes) }
    }
}

extension Date {
    var roundedToSecond: Date { Date(timeIntervalSince1970: (timeIntervalSince1970).rounded()) }
}
