import AppKit
import TikjotDomain
import TikjotPersistence
import UserNotifications

/// Actionable notifications (§11.6), quiet in Focus (system handles it). Every kind can be turned off.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    enum Kind: String {
        case longTimer, nothingTicking, slept, unsentDays, sendFailed, signedOut, fridayRecap, mondayHole, menuBarHidden
        case firstDay
    }

    /// The day of the one evening nudge after onboarding ("yyyy-MM-dd"; removed once it was shown or the day passed).
    static let firstDayNudgeKey = "onboarding.firstDayNudge"

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    private(set) var authorized: Bool?

    func setUp() {
        center.delegate = self
        let a = { (id: String, title: String, fg: Bool) in UNNotificationAction(identifier: id, title: title, options: fg ? [.foreground] : []) }
        // With previews hidden (locked screen / "Show previews: When unlocked"), only this placeholder shows —
        // never a task name or description from the title or body.
        let hidden = String(localized: "tikjot reminder")
        let category = { (kind: Kind, actions: [UNNotificationAction]) in
            UNNotificationCategory(identifier: kind.rawValue, actions: actions, intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hidden, options: [])
        }
        center.setNotificationCategories([
            category(.longTimer, [a("continue", String(localized: "Continue"), false), a("stop", String(localized: "Stop"), false), a("stop1h", String(localized: "Stop 1 h ago"), false)]),
            category(.nothingTicking, [a("startLast", String(localized: "Start last"), false), a("choose", String(localized: "Choose task…"), true)]),
            category(.slept, [a("keep", String(localized: "Keep it"), false), a("cut", String(localized: "Cut it"), false)]),
            category(.unsentDays, [a("review", String(localized: "Review & send"), true)]),
            category(.firstDay, [a("review", String(localized: "Review & send"), true)]),
            category(.sendFailed, [a("fix", String(localized: "Fix"), true)]),
            category(.signedOut, [a("renew", String(localized: "Renew token"), true)]),
            category(.mondayHole, [a("addAbsence", String(localized: "Add absence…"), true), a("openDay", String(localized: "Open the day"), true)]),
            category(.fridayRecap, []), category(.menuBarHidden, []),
        ])
        refreshAuthorization()
    }

    func refreshAuthorization() {
        center.getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            Task { @MainActor in self.authorized = ok }
        }
    }

    func requestAuthorization() async -> Bool {
        let ok = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        authorized = ok
        return ok
    }

    /// Demo mode: nothing reaches Notification Center.
    var muted = false

    func post(_ kind: Kind, title: String, body: String, userInfo: [String: Any] = [:], id: String? = nil) {
        guard !muted else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.categoryIdentifier = kind.rawValue
        c.userInfo = userInfo
        c.interruptionLevel = .active
        center.add(UNNotificationRequest(identifier: id ?? kind.rawValue, content: c, trigger: nil))
    }

    func remove(_ kind: Kind) {
        center.removeDeliveredNotifications(withIdentifiers: [kind.rawValue])
    }

    /// Delete all data: nothing of it stays in Notification Center either.
    func removeAll() {
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    // MARK: Messages (designed copy, Notifications board)

    func longTimer(_ e: TimeEntry, task: String) {
        post(.longTimer, title: String(localized: "Still working on \(task)?"),
             body: String(localized: "The timer has been running for \(DurationFormat.hm(Int(Clock.now.timeIntervalSince(e.start))))."),
             userInfo: [Self.entryKey: e.id.uuidString])
    }

    func nothingTicking(last: String?) {
        post(.nothingTicking, title: String(localized: "Back at it? Nothing's ticking"),
             body: last.map { String(localized: "Continue “\($0)” — or pick something else.") } ?? String(localized: "Start the timer so today counts."))
    }

    func slept(minutes: Int) {
        post(.slept, title: String(localized: "Your Mac slept \(DurationFormat.hm(minutes * 60))"),
             body: String(localized: "The timer kept running. Keep that time or cut it?"),
             userInfo: AppDelegate.shared?.model?.runningEntry.map { [Self.entryKey: $0.id.uuidString] } ?? [:])
    }

    /// The morning reminder. When some of the days are last month's (still open), it says when that month locks —
    /// this replaced the separate "Month closing" reminder (simplicity pass 2026-10-06).
    func unsentDays(_ n: Int, closing: (month: String, lastOpenDay: String)? = nil) {
        if let closing {
            let days = String(localized: "\(n) days not in Jira")
            post(.unsentDays, title: String(localized: "\(closing.month) locks after \(closing.lastOpenDay) — \(days)"),
                 body: String(localized: "Send what's left before it locks."))
            return
        }
        post(.unsentDays, title: n == 1 ? String(localized: "1 day is not in Jira yet") : String(localized: "\(n) days are not in Jira yet"),
             body: String(localized: "Review and send them in a minute."))
    }

    /// Day 1, end of the working day (design hOI5c): the first send is the habit.
    func firstDay(tracked: Seconds) {
        post(.firstDay, title: String(localized: "Send today to Jira"),
             body: String(localized: "it takes 2 minutes · \(DurationFormat.hm(tracked)) tracked today"))
    }

    func mondayHole(_ d: String) {
        post(.mondayHole, title: String(localized: "Last week has a hole"), body: String(localized: "\(d) has nothing tracked. Add an absence or open the day."))
    }

    func sendFailed(count: Int) {
        post(.sendFailed, title: String(localized: "\(count) worklogs didn't make it to Jira"), body: String(localized: "Open tikjot to see why and fix them."))
    }

    func signedOut(instance: JiraInstance) {
        // Usually an expired API token (tikjot doesn't track expiry dates; Jira's 401 is the signal — decided 2026-10-06).
        post(.signedOut, title: String(localized: "Jira signed you out"),
             body: String(localized: "\(instance.name): your token may have expired. Paste a new one; tracking still works."),
             userInfo: [Self.instanceKey: instance.id.uuidString], id: "signedOut-\(instance.id)")
    }

    func fridayRecap(week: Int, total: String) {
        post(.fridayRecap, title: String(localized: "Week \(week) is in Jira"), body: String(localized: "\(total) sent. Have a good weekend."))
    }

    func menuBarHidden(hotkey: String) {
        post(.menuBarHidden, title: String(localized: "tikjot is hidden in your menu bar"),
             body: String(localized: "The menu bar is full. Press \(hotkey) to open the timer, or open tikjot to move it back into view."))
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let entry = (response.notification.request.content.userInfo[Self.entryKey] as? String).flatMap(UUID.init(uuidString:))
        let instance = (response.notification.request.content.userInfo[Self.instanceKey] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run { self.handle(action: action, category: category, entry: entry, instance: instance) }
    }

    /// The timer entry a notification is about (long timer, slept).
    nonisolated static let entryKey = "entryId"
    /// The Jira connection a notification is about (token expiring).
    nonisolated static let instanceKey = "instanceId"
    /// Buttons that change the running timer. "keep" / "cut" answer the away card instead, which knows the entry
    /// it's about (also after a switch).
    static let timerActions: Set<String> = ["continue", "stop", "stop1h"]

    func handle(action: String, category: String, entry: UUID? = nil, instance: UUID? = nil) {
        guard let model = AppDelegate.shared?.model else { return }
        let windows = AppDelegate.shared?.windows
        // An older notification's button acts only on the timer it was about: if that one has stopped (or another
        // runs now), just show the timer.
        if Self.timerActions.contains(action), entry == nil || model.runningEntry?.id != entry {
            MenuBarController.shared?.showPopover()
            return
        }
        switch action {
        case "continue": break
        case "stop": model.stop()
        case "stop1h": model.stop(at: Clock.now.addingTimeInterval(-3600))
        case "startLast":
            if let last = model.data.entries.last(where: { $0.end != nil && $0.kind == .work }) { model.continueEntry(last) }
        case "choose": MenuBarController.shared?.showPopover(); model.popoverEditing = .picker(.timer)
        case "keep": model.keepAway()
        case "cut": model.cutAway()
        case "review", "fix": model.openReviewFromPopover()
        case "renew":
            if let instance { model.requestTokenRenewal(instance) } else { windows?.showSettings(model, tab: .jira) }
        case "addAbsence": MenuBarController.shared?.showPopover(); model.popoverEditing = .absence
        case "openDay": if let d = model.mondayHoles.first { model.openDay(d) }
        default:
            // Tapped the banner itself.
            switch category {
            case Kind.slept.rawValue, Kind.longTimer.rawValue, Kind.nothingTicking.rawValue, Kind.mondayHole.rawValue: MenuBarController.shared?.showPopover()
            case Kind.signedOut.rawValue:
                if let instance { model.requestTokenRenewal(instance) } else { windows?.showSettings(model, tab: .jira) }
            case Kind.firstDay.rawValue: model.openReviewFromPopover()
            default: windows?.showMain(model)
            }
        }
    }
}
