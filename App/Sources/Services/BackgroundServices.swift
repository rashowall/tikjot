import AppKit
import CoreGraphics
import Network
import ServiceManagement
import TikjotDomain
import TikjotPersistence
import WidgetKit

/// Everything that runs while tikjot sits in the menu bar: clock, sleep/lock tracking, reminders (§7.2),
/// auto refresh (§9.9), daily snapshots (§13), widget data (§11.5), hotkeys and launch at login.
@MainActor
final class BackgroundServices {
    let model: AppModel
    let hotkeys = Hotkeys()
    private var tickTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var sleptAt: Date?
    private var lockedAt: Date?
    private var activeSeconds: TimeInterval = 0
    private var lastRefresh = Date.distantPast
    /// The last tick found you away (no input for 2 min, or the screen locked).
    private var wasAway = false
    private var widgetWrite: DispatchWorkItem?
    /// Notification bookkeeping (in memory + key/value store for once-per-day ones).
    private var notifiedLongTimer: UUID?
    private var lastNothingTicking = Date.distantPast
    /// Network changes (VPN up, Wi-Fi back) end an "unreachable" state right away.
    private let pathMonitor = NWPathMonitor()

    init(model: AppModel) { self.model = model }

    func start() {
        // Demo (captures, UI tests) stays out of the everyday tikjot's way: no notifications,
        // no global hotkeys, no widget commands.
        NotificationService.shared.muted = model.demo
        NotificationService.shared.setUp()
        if !model.demo { registerHotkeys() }
        applyLaunchAtLogin()
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleptAt = Clock.now }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockedAt = Clock.now }
        })
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didUnlock() }
        })
        // Widget commands (Stop / Continue buttons) arrive as a Darwin notification.
        if !model.demo { WidgetBridge.observeCommands { [weak self] in self?.handleWidgetCommands() } }

        model.userAway = { [weak self] in
            MainActor.assumeIsolated { self.map { $0.idleSeconds >= 120 || $0.lockedAt != nil } ?? false }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        model.onDataChange.append { [weak self] in self?.scheduleWidgetWrite() }
        scheduleWidgetWrite()
        takeSnapshot()
        model.splitRunningAtMidnight()
        model.restoreAwayPrompt()
        model.observeTextEditing()
        Task { await refresh(reason: "launch") }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.model.networkChanged() }
        }
        pathMonitor.start(queue: .main)
        checkMonday()
    }

    func stop() {
        tickTimer?.invalidate()
        pathMonitor.cancel()
        writeWidget()
    }

    func registerHotkeys() {
        let m = model
        let open: @MainActor @Sendable () -> Void = {
            MenuBarController.shared?.showPopover()
            // Idle: the description field with your recent work; running: switch via the task field.
            if m.runningEntry == nil { m.focusTimerDescription() } else { m.popoverEditing = .picker(.timer) }
        }
        let stop: @MainActor @Sendable () -> Void = { m.toggleTimer() }
        hotkeys.register([(model.settings.hotkeyOpen, open), (model.settings.hotkeyStop, stop)])
    }

    func applyLaunchAtLogin() {
        guard !model.demo else { return }
        let svc = SMAppService.mainApp
        if model.settings.launchAtLogin {
            if svc.status != .enabled { try? svc.register() }
        } else if svc.status == .enabled {
            try? svc.unregister()
        }
    }

    // MARK: Clock & reminders

    /// Fixed since the simplicity pass (2026-10-06): Settings has only the switches. The stored
    /// `longTimerReminderHours` / `sleepPromptMinutes` stay in AppSettings (old data decodes) but aren't read.
    static let longTimerAfter: TimeInterval = 3 * 3600
    static let awayPromptAfter: TimeInterval = 15 * 60

    private var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Moves the model's clock to now. A new day (midnight passed — also while the Mac slept) splits the running
    /// timer at 00:00: the day is compared with the reading from *before* the clock moves (S-wake).
    private func advanceClock() {
        let previous = model.now
        model.now = Clock.now
        if AwayOps.dayChanged(from: previous, to: model.now, calendar: model.timeCalendar) {
            model.splitRunningAtMidnight(); model.reconcile(); checkMonday()
        }
    }

    func tick() {
        advanceClock()
        model.dropStaleAwayPrompt()
        let idle = idleSeconds
        if idle < 60 { activeSeconds += 15 } else { activeSeconds = 0 }
        // Back at the Mac: what waited for you (an unreachable Jira's retry) and anything older than 5 min, at once.
        let away = idle >= 120 || lockedAt != nil
        if wasAway && !away && model.userIsBack() {
            Task { await refresh(reason: "back") }
        } else if !away, Clock.now.timeIntervalSince(lastRefresh) > Double(model.settings.autoRefreshMinutes * 60) {
            // Auto refresh every N minutes, only while the user is active.
            Task { await refresh(reason: "timer") }
        }
        wasAway = away
        checkReminders()
    }

    func refresh(reason: String) async {
        lastRefresh = Clock.now
        await model.refreshAll(reason: reason)
    }

    private func checkReminders() {
        let s = model.settings
        let now = Clock.now
        let today = model.today
        let cal = model.dayCalendar
        let period = model.schedule.period(on: today)
        let minutes = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)
        let inWorkingHours = minutes >= period.workdayStart && minutes < period.workdayEnd
        let workday = cal.isWorkday(today) && !cal.isDayOff(today)

        // Timer running long.
        if let r = model.runningEntry, s.longTimerReminderEnabled,
           now.timeIntervalSince(r.start) > Self.longTimerAfter, notifiedLongTimer != r.id {
            notifiedLongTimer = r.id
            NotificationService.shared.longTimer(r, task: model.taskLabel(for: r))
        }
        // Nothing's ticking while active in working hours.
        if model.runningEntry == nil, s.idleReminderEnabled, workday, inWorkingHours,
           activeSeconds >= Double(s.idleReminderMinutes * 60), now.timeIntervalSince(lastNothingTicking) > 3600 {
            lastNothingTicking = now
            let last = model.data.entries.last(where: { $0.end != nil && $0.kind == .work })
            NotificationService.shared.nothingTicking(last: last.map { $0.description.isEmpty ? model.taskLabel(for: $0) : $0.description })
        }
        // Morning: unsent older days (once a day). Some of them last month's (still open) → it says when that month
        // locks (this replaced the separate "Month closing" reminder).
        if s.unsentReminderEnabled, model.jiraConnected, minutes >= period.workdayStart, activeSeconds > 0, onceToday("unsentDays") {
            let days = model.unsentDays().filter { $0 < today }
            if !days.isEmpty, markOnce("unsentDays") {
                let lastMonth = days.first { $0 < today.firstOfMonth }
                NotificationService.shared.unsentDays(days.count, closing: lastMonth.map {
                    (Fmt.monthName($0), Fmt.dayMonth(model.lock.editableUntil($0)))
                })
            }
        }
        // Day 1 after onboarding (design hOI5c): once, at the end of working hours, while today isn't in Jira yet.
        let defaults = UserDefaults.standard
        if let day = defaults.string(forKey: NotificationService.firstDayNudgeKey).flatMap({ LocalDate($0) }) {
            switch Nudges.firstDay(nudgeDay: day, today: today, minutes: minutes, workdayEnd: period.workdayEnd, todayUnsent: model.jiraConnected && model.unsentDays().contains(today)) {
            case .drop: defaults.removeObject(forKey: NotificationService.firstDayNudgeKey)
            case .show:
                defaults.removeObject(forKey: NotificationService.firstDayNudgeKey)
                if markOnce("firstDay") { NotificationService.shared.firstDay(tracked: model.ledger.worked(today)) }
            case .wait: break
            }
        }
        // Friday recap at 16:00 when the whole week is in Jira.
        if s.fridayRecapEnabled, today.isoWeekday == 5, minutes >= 16 * 60, onceToday("fridayRecap"), model.jiraConnected {
            let week = DateRange(today.startOfWeek, today)
            let worked = model.ledger.worked(week)
            if worked > 0, !week.contains(where: { [.waiting, .failed, .conflict].contains(model.ledger.dayStatus($0, lock: model.lock)) }), markOnce("fridayRecap") {
                NotificationService.shared.fridayRecap(week: today.weekNumber, total: DurationFormat.hm(model.ledger.inJira(week)))
            }
        }
    }

    private func onceToday(_ key: String) -> Bool {
        (UserDefaults.standard.string(forKey: "notified.\(key)") ?? "") != model.today.description
    }

    @discardableResult
    private func markOnce(_ key: String) -> Bool {
        guard onceToday(key) else { return false }
        UserDefaults.standard.set(model.today.description, forKey: "notified.\(key)")
        return true
    }

    // MARK: Sleep, lock & Monday check

    private func didWake() {
        defer { sleptAt = nil }
        advanceClock()
        model.lastWake = Clock.now
        // The VPN usually needs a few seconds after wake; an early miss is retried (scheduleOfflineRetry).
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await refresh(reason: "wake")
        }
        guard let from = sleptAt, model.runningEntry != nil else { return }
        let away = Clock.now.timeIntervalSince(from)
        if model.sleepPromptEnabled, away > Self.awayPromptAfter {
            model.awayPrompt = AwayPrompt(from: from, to: Clock.now, slept: true, entryId: model.runningEntry!.id)
            NotificationService.shared.slept(minutes: Int(away / 60))
        }
    }

    private func didUnlock() {
        defer { lockedAt = nil }
        advanceClock()
        checkMonday()
        guard let from = lockedAt, model.runningEntry != nil, model.awayCard == nil else { return }
        let away = Clock.now.timeIntervalSince(from)
        if model.sleepPromptEnabled, away > Self.awayPromptAfter {
            model.awayPrompt = AwayPrompt(from: from, to: Clock.now, slept: false, entryId: model.runningEntry!.id)
        }
    }

    /// Monday, first unlock: last week's empty workdays (§11.11).
    func checkMonday() {
        let today = model.today
        guard today.isoWeekday == 1, onceToday("monday") else { return }
        let lastWeek = DateRange(today.adding(days: -7), today.adding(days: -3))
        let holes = lastWeek.filter { model.ledger.dayStatus($0, lock: model.lock, jiraConnected: model.jiraConnected) == .missed }
        model.mondayHoles = holes
        if let first = holes.first, markOnce("monday") {
            NotificationService.shared.mondayHole(Fmt.weekday(first))
        }
    }

    // MARK: Snapshots

    func takeSnapshot() {
        guard model.settings.snapshotsEnabled, !model.demo else { return }
        do {
            try SnapshotManager(directory: Paths.snapshots).takeIfNeeded(model.db, keep: model.settings.snapshotsKeep)
            model.snapshotError = nil
        } catch {
            Log.error("snapshot failed: \(SafeError.describe(error))")
            model.snapshotError = SafeError.describe(error)
        }
    }

    // MARK: Widget

    /// macOS gives widgets a daily reload budget; spending it on every sync left the widget showing an old task for
    /// up to an hour. So: the snapshot file is always rewritten (any reload then shows the truth), a reload is asked
    /// only when something the widget shows changed, and start / stop / switch go out at once — while the popover is
    /// still open and the app is in front.
    private var lastWidgetSignature: Data?
    private var lastRunningKey: String?

    private func scheduleWidgetWrite() {
        widgetWrite?.cancel()
        let r = model.runningEntry
        let running = r.map { "\($0.id)|\($0.issueId ?? "")|\($0.projectId?.uuidString ?? "")|\($0.description)|\($0.start.timeIntervalSince1970)" } ?? "-"
        if running != lastRunningKey {
            lastRunningKey = running
            writeWidget()
            return
        }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.writeWidget() } }
        widgetWrite = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    func writeWidget() {
        guard !model.demo || LaunchFlags.args.contains("-demoWidget") else { return }
        let snap = WidgetSnapshot.make(model)
        WidgetBridge.write(snap)
        let sig = snap.reloadSignature(now: Clock.now)
        guard sig != lastWidgetSignature else { return }
        lastWidgetSignature = sig
        WidgetCenter.shared.reloadTimelines(ofKind: "today")
    }

    private func handleWidgetCommands() {
        for cmd in WidgetBridge.takeCommands() {
            switch cmd {
            case "stop": model.stop()
            case "continue":
                if let last = model.data.entries.last(where: { $0.end != nil && $0.kind == .work }) { model.continueEntry(last) }
            case "switch": MenuBarController.shared?.showPopover(); model.popoverEditing = .picker(.timer)
            default: break
            }
        }
    }
}

extension AppModel {
    /// "● KEY Name" as plain text, for notifications.
    func taskLabel(for e: TimeEntry) -> String {
        if let i = issue(for: e) { return "\(i.key) \(i.summary)" }
        return project(e.projectId)?.name ?? String(localized: "No task")
    }

    /// Give the away time to another task — out of the timer that ran (it ends when you left and goes on after
    /// it), or after a switch out of the finished entry it was (split around it).
    func giveAway(to issue: Issue?, projectId: UUID?) {
        guard let p = awayPrompt, let owner = awayOwner(p) else { awayPrompt = nil; return }
        var away = TimeEntry(start: p.from, end: p.to, instanceId: issue?.instanceId, issueId: issue?.issueId,
                             projectId: projectId ?? issue.flatMap(self.projectId(for:)), description: "")
        var c = Changes()
        switch owner {
        case .running(let r):
            // The timer (and its midnight parts, if the Mac slept past 00:00) ends when you left.
            let stopped = AwayOps.stop(at: p.from, running: r, entries: data.entries)
            let mid = EntryOps.normalizeMidnight(away, calendar: timeCalendar)
            if !mid.isEmpty { away = mid.updated[0] }
            let cont = TimeEntry(start: p.to, end: nil, instanceId: r.instanceId, issueId: r.issueId, projectId: r.projectId, description: r.description)
            c.upsertEntries = stopped.updated + [away] + mid.inserted + [cont]
            c.deleteEntries = stopped.deleted.map(\.id)
        case .finished(let e):
            guard let ch = try? EntryOps.carve(e, from: p.from, to: p.to, replacement: away) else { awayPrompt = nil; return }
            c.upsertEntries = ch.updated + ch.inserted
            c.deleteEntries = ch.deleted.map(\.id)
        }
        perform("Give away time to another task", c)
        awayPrompt = nil
    }
}
