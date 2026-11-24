import Foundation
import SyncEngine
import TikjotDomain
import TikjotPersistence

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, jira, workTime, tracking, backup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .jira: return String(localized: "Jira")
        case .workTime: return String(localized: "Work time")
        case .tracking: return String(localized: "Tracking")
        case .backup: return String(localized: "Backup")
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .jira: return "powerplug"
        case .workTime: return "calendar.badge.clock"
        case .tracking: return "stopwatch"
        case .backup: return "externaldrive"
        }
    }
}

enum PopoverEditing: Equatable {
    case startTime
    case picker(PickerTarget)
    case entry(UUID)
    case absence
    case newProject
    case menu
}

enum PickerTarget: Equatable {
    /// The timer capsule (start / switch).
    case timer
    /// Give an existing entry a task.
    case entry(UUID)
}

struct AwayPrompt: Equatable, Identifiable {
    var id: Date { from }
    let from: Date
    let to: Date
    let slept: Bool
    /// The timer that ran while you were away — the card stays about it after you switch (beta 2026-10-18).
    let entryId: UUID
    var seconds: Int { Int(to.timeIntervalSince(from)) }
}

/// What the away card is about now.
enum AwayOwner: Equatable {
    /// That timer still runs: stop it when you left, keep it, or give the time to another task.
    case running(TimeEntry)
    /// You switched (or stopped) since: the time away sits inside this finished entry.
    case finished(TimeEntry)
}

extension AppModel {
    /// Days in the editable window that aren't fully in Jira (popover "Review & send", reminders).
    func unsentDays() -> [LocalDate] {
        let start = lock.isLocked(today.firstOfMonth.adding(days: -1), today: today) ? today.firstOfMonth : today.firstOfMonth.adding(months: -1)
        return DateRange(start, today).filter { d in
            let s = ledger.dayStatus(d, lock: lock, jiraConnected: jiraConnected)
            return s == .waiting || s == .failed || s == .conflict
        }
    }

    /// Workdays that are over with nothing tracked in the editable window.
    func missedDays() -> [LocalDate] {
        let start = today.firstOfMonth.adding(months: -1)
        return DateRange(start, today).filter { ledger.dayStatus($0, lock: lock, jiraConnected: jiraConnected) == .missed }
    }

    func requestReview(days: [LocalDate], title: String) {
        reviewRequest = ReviewRequest(scope: .days(days), title: title, name: reviewName(days))
    }

    /// "today" / "Thu 1 Oct" for a day, "Week 41" for a whole week, "October" for a whole month.
    private func reviewName(_ days: [LocalDate]) -> String? {
        let ds = Set(days)
        guard let first = ds.min(), let last = ds.max() else { return nil }
        if ds.count == 1 { return Fmt.dayName(first, today: today) }
        if DateRange.week(of: first) == DateRange(first, last), ds.count == 7 { return String(localized: "Week \(first.weekNumber)") }
        if DateRange.month(of: first) == DateRange(first, last), ds.count == DateRange.month(of: first).count { return Fmt.monthName(first) }
        return nil
    }

    func requestReview(groups: Set<UUID>, title: String) {
        reviewRequest = ReviewRequest(scope: .groups(groups), title: title)
    }

    func requestReviewForSelection() {
        switch mainSelection {
        case .week:
            requestReview(days: Array(DateRange.week(of: selectedDay)), title: String(localized: "Send week \(selectedDay.weekNumber) to Jira"))
        case .month:
            requestReview(days: Array(DateRange.month(of: selectedDay)), title: String(localized: "Send \(Fmt.monthName(selectedDay)) to Jira"))
        case .unsent:
            requestReview(days: unsentDays(), title: String(localized: "Send to Jira"))
        default:
            requestReview(days: [selectedDay], title: String(localized: "Send \(Fmt.dayName(selectedDay, today: today)) to Jira"))
        }
        AppDelegate.shared?.windows.showMain(self)
    }

    /// Popover "Review & send": opens the main window with the Review sheet for today (§11.1).
    func openReviewFromPopover() {
        MenuBarController.shared?.closePopover()
        mainSelection = .day
        selectedDay = today
        let days = unsentDays()
        requestReview(days: days.contains(today) || days.isEmpty ? [today] : days, title: String(localized: "Send \(Fmt.dayName(days.contains(today) || days.isEmpty ? today : days.last!, today: today)) to Jira"))
        AppDelegate.shared?.windows.showMain(self)
    }

    func openDay(_ d: LocalDate) {
        MenuBarController.shared?.closePopover()
        selectedDay = d
        mainSelection = .day
        AppDelegate.shared?.windows.showMain(self)
    }
}
