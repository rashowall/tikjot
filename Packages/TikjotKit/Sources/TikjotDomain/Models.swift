import Foundation

// SPEC §6 — every entity has an id, timestamps and a soft-delete marker (ready for iCloud sync later).

public typealias Seconds = Int

// MARK: Jira instance (§6.1)

public enum JiraKind: String, Codable, Sendable, CaseIterable {
    case cloud
    case dataCenter
}

public enum JiraAuthMethod: String, Codable, Sendable {
    case cloudApiToken   // email + API token → Basic
    case pat             // Bearer
    case basic           // username + password (DC fallback)
}

public enum JiraInstanceStatus: String, Codable, Sendable {
    case active
    case authError
    case archived
}

public struct JiraInstance: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: JiraKind
    public var baseURL: URL
    public var authMethod: JiraAuthMethod
    /// Login shown in Settings (email for Cloud, username for DC). The secret lives in the Keychain.
    public var login: String
    public var accountId: String?
    public var displayName: String?
    public var jiraTimeZone: String?
    public var status: JiraInstanceStatus
    public var successorOf: UUID?
    public var successionDate: LocalDate?
    public var lastSyncAt: Date?
    public var syncCursor: Date?
    public var historyStartDate: LocalDate?
    /// DEPRECATED, unused since 2026-10-06 (the token-expiry warning was removed; an expired token shows up as Jira's
    /// 401 → "signed out"). Kept only so databases (column from migration v3), snapshots and backups that carry it
    /// still open; nothing writes or reads it any more. Don't build on it.
    public var tokenExpires: LocalDate?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), name: String, kind: JiraKind, baseURL: URL, authMethod: JiraAuthMethod,
                login: String, accountId: String? = nil, displayName: String? = nil, jiraTimeZone: String? = nil,
                status: JiraInstanceStatus = .active, successorOf: UUID? = nil, successionDate: LocalDate? = nil,
                lastSyncAt: Date? = nil, syncCursor: Date? = nil, historyStartDate: LocalDate? = nil, tokenExpires: LocalDate? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.baseURL = baseURL; self.authMethod = authMethod
        self.login = login; self.accountId = accountId; self.displayName = displayName; self.jiraTimeZone = jiraTimeZone
        self.status = status; self.successorOf = successorOf; self.successionDate = successionDate
        self.lastSyncAt = lastSyncAt; self.syncCursor = syncCursor; self.historyStartDate = historyStartDate
        self.tokenExpires = tokenExpires
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

// MARK: Project (§6.2, §6.3)

public struct Project: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// Name of a palette colour (`ProjectColor`) or a custom hex (`#RRGGBB`).
    public var color: String
    public var billable: Bool
    public var excludeFromWorked: Bool
    public var archived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), name: String, color: String, billable: Bool = true, excludeFromWorked: Bool = false,
                archived: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.name = name; self.color = color; self.billable = billable
        self.excludeFromWorked = excludeFromWorked; self.archived = archived
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

public enum ProjectRuleType: String, Codable, Sendable {
    case jiraProjectKey
}

public struct ProjectRule: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var type: ProjectRuleType
    public var instanceId: UUID
    public var value: String
    public var priority: Int

    public init(id: UUID = UUID(), projectId: UUID, type: ProjectRuleType = .jiraProjectKey, instanceId: UUID, value: String, priority: Int = 0) {
        self.id = id; self.projectId = projectId; self.type = type; self.instanceId = instanceId
        self.value = value.uppercased(); self.priority = priority
    }
}

// MARK: Issue cache (§6.4)

public enum StatusCategory: String, Codable, Sendable {
    case new, indeterminate, done
}

public enum IssueAvailability: String, Codable, Sendable {
    case ok, deleted, noPermission
}

public struct Issue: Hashable, Codable, Sendable, Identifiable {
    public var id: String { "\(instanceId.uuidString)/\(issueId)" }
    public var instanceId: UUID
    /// Stable Jira id — the identity.
    public var issueId: String
    /// Mutable; updated when the issue moves.
    public var key: String
    public var summary: String
    public var issueType: String?
    public var statusName: String?
    public var statusCategory: StatusCategory
    public var parentKey: String?
    public var parentSummary: String?
    /// Name of the Jira project (used to name an automatically created tikjot project).
    public var projectName: String?
    public var assignedToMe: Bool
    public var originalEstimateSeconds: Seconds?
    public var timeSpentSeconds: Seconds?
    public var updated: Date?
    public var availability: IssueAvailability
    public var pinned: Bool
    public var pinOrder: Int
    public var fetchedAt: Date
    /// Where it was seen: assigned / logged / filter:<id> / search.
    public var sources: Set<String>

    public init(instanceId: UUID, issueId: String, key: String, summary: String, issueType: String? = nil,
                statusName: String? = nil, statusCategory: StatusCategory = .indeterminate, parentKey: String? = nil,
                parentSummary: String? = nil, projectName: String? = nil, assignedToMe: Bool = false, originalEstimateSeconds: Seconds? = nil,
                timeSpentSeconds: Seconds? = nil, updated: Date? = nil, availability: IssueAvailability = .ok,
                pinned: Bool = false, pinOrder: Int = 0, fetchedAt: Date = Date(), sources: Set<String> = []) {
        self.instanceId = instanceId; self.issueId = issueId; self.key = key; self.summary = summary
        self.issueType = issueType; self.statusName = statusName; self.statusCategory = statusCategory
        self.parentKey = parentKey; self.parentSummary = parentSummary; self.projectName = projectName; self.assignedToMe = assignedToMe
        self.originalEstimateSeconds = originalEstimateSeconds; self.timeSpentSeconds = timeSpentSeconds
        self.updated = updated; self.availability = availability; self.pinned = pinned; self.pinOrder = pinOrder
        self.fetchedAt = fetchedAt; self.sources = sources
    }

    /// Jira project key part of the issue key ("PMO-415" → "PMO").
    public var projectKey: String { Issue.projectKey(of: key) }

    public static func projectKey(of key: String) -> String {
        String(key.split(separator: "-").first ?? Substring(key)).uppercased()
    }

    public var isDone: Bool { statusCategory == .done }
}

/// A reference to a Jira issue: instance + stable id.
public struct IssueRef: Hashable, Codable, Sendable {
    public var instanceId: UUID
    public var issueId: String
    public init(instanceId: UUID, issueId: String) { self.instanceId = instanceId; self.issueId = issueId }
}

// MARK: Time entry (§6.5)

public enum EntrySource: String, Codable, Sendable {
    case local
    case imported
}

public enum EntryKind: String, Codable, Sendable {
    /// Ordinary work.
    case work
    /// A gap marked as a break (§11.11) — never counts as worked, never sent.
    case breakTime
}

public struct TimeEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var start: Date
    /// `nil` only for the running timer.
    public var end: Date?
    public var instanceId: UUID?
    public var issueId: String?
    public var projectId: UUID?
    public var description: String
    public var source: EntrySource
    public var kind: EntryKind
    public var worklogGroupId: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), start: Date, end: Date?, instanceId: UUID? = nil, issueId: String? = nil,
                projectId: UUID? = nil, description: String = "", source: EntrySource = .local, kind: EntryKind = .work,
                worklogGroupId: UUID? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.start = start; self.end = end; self.instanceId = instanceId; self.issueId = issueId
        self.projectId = projectId; self.description = description; self.source = source; self.kind = kind
        self.worklogGroupId = worklogGroupId; self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public var isRunning: Bool { end == nil }
    public var hasIssue: Bool { instanceId != nil && issueId != nil }
    public var issueRef: IssueRef? {
        guard let instanceId, let issueId else { return nil }
        return IssueRef(instanceId: instanceId, issueId: issueId)
    }

    /// Raw duration; a running entry is measured up to `now`.
    public func duration(now: Date) -> Seconds {
        let s = (end ?? now).timeIntervalSince(start)
        // Bounded so dates from a damaged or crafted backup can't trap the conversion.
        guard s.isFinite, s > 0 else { return 0 }
        return Int(Swift.min(s, 1e12).rounded())
    }

    public func effectiveEnd(now: Date) -> Date { end ?? max(now, start) }
}

// MARK: Worklog group (§6.6)

public enum WorklogGroupKind: String, Codable, Sendable {
    /// Aggregates all local entries for issue + day.
    case app
    /// Exactly one imported entry.
    case imported
}

/// §9.6
public enum SyncState: String, Codable, Sendable, CaseIterable {
    case noIssue
    case unsent
    case synced
    case modified
    case pendingDelete
    case conflict
    case error
    case remoteDeleted
    case locked
}

public struct SentSnapshot: Hashable, Codable, Sendable {
    public var startedAt: Date
    public var durationSeconds: Seconds
    public var comment: String
    public init(startedAt: Date, durationSeconds: Seconds, comment: String) {
        self.startedAt = startedAt; self.durationSeconds = durationSeconds; self.comment = comment
    }
}

public struct SyncErrorInfo: Hashable, Codable, Sendable {
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}

public struct WorklogGroup: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var instanceId: UUID
    public var issueId: String
    public var localDate: LocalDate
    public var kind: WorklogGroupKind
    public var remoteWorklogId: String?
    public var remoteUpdated: Date?
    /// What is in Jira right now (after the last send or import).
    public var lastSent: SentSnapshot?
    /// Raw local total when `lastSent` was written — while it is unchanged the Jira value stands
    /// (rounding changes never re-round synced worklogs, §8.1).
    public var sentRaw: Seconds?
    /// Jira's version when it differs from `lastSent` (conflict or locked change).
    public var remoteVersion: SentSnapshot?
    public var syncState: SyncState
    public var lastError: SyncErrorInfo?
    public var commentOverride: String?
    /// The override was written for a different set of descriptions (§9.3).
    public var commentOverrideStale: Bool
    /// "changed in Jira (was …)" marker for locked periods (§8.6).
    public var changedInJiraWas: Seconds?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), instanceId: UUID, issueId: String, localDate: LocalDate, kind: WorklogGroupKind = .app,
                remoteWorklogId: String? = nil, remoteUpdated: Date? = nil, lastSent: SentSnapshot? = nil, sentRaw: Seconds? = nil,
                remoteVersion: SentSnapshot? = nil, syncState: SyncState = .unsent, lastError: SyncErrorInfo? = nil,
                commentOverride: String? = nil, commentOverrideStale: Bool = false, changedInJiraWas: Seconds? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.instanceId = instanceId; self.issueId = issueId; self.localDate = localDate; self.kind = kind
        self.remoteWorklogId = remoteWorklogId; self.remoteUpdated = remoteUpdated; self.lastSent = lastSent; self.sentRaw = sentRaw
        self.remoteVersion = remoteVersion; self.syncState = syncState; self.lastError = lastError
        self.commentOverride = commentOverride; self.commentOverrideStale = commentOverrideStale
        self.changedInJiraWas = changedInJiraWas
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public var issueRef: IssueRef { IssueRef(instanceId: instanceId, issueId: issueId) }
}

// MARK: Work schedule (§6.7)

/// One effective-dated version of the contract.
public struct WorkSchedulePeriod: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var effectiveFrom: LocalDate
    public var dailyHours: Double
    /// ISO weekdays (1 = Monday) that are workdays.
    public var workdays: Set<Int>
    /// Minutes after midnight.
    public var workdayStart: Int
    public var workdayEnd: Int

    public init(id: UUID = UUID(), effectiveFrom: LocalDate, dailyHours: Double = 8, workdays: Set<Int> = [1, 2, 3, 4, 5],
                workdayStart: Int = 8 * 60, workdayEnd: Int = 16 * 60 + 30) {
        self.id = id; self.effectiveFrom = effectiveFrom; self.dailyHours = dailyHours; self.workdays = workdays
        self.workdayStart = workdayStart; self.workdayEnd = workdayEnd
    }

    public var dailySeconds: Seconds { dailyHours.isFinite ? Int((Swift.min(Swift.max(dailyHours, 0), 24) * 3600).rounded()) : 0 }
}

public struct WorkSchedule: Hashable, Codable, Sendable {
    /// Sorted by `effectiveFrom`.
    public private(set) var periods: [WorkSchedulePeriod]

    public init(periods: [WorkSchedulePeriod]) {
        precondition(!periods.isEmpty, "A schedule needs at least one period")
        self.periods = periods.sorted { $0.effectiveFrom < $1.effectiveFrom }
    }

    public static let standard = WorkSchedule(periods: [WorkSchedulePeriod(effectiveFrom: LocalDate(year: 2000, month: 1, day: 1))])

    public func period(on date: LocalDate) -> WorkSchedulePeriod {
        periods.last { $0.effectiveFrom <= date } ?? periods[0]
    }

    public var current: WorkSchedulePeriod { periods.last! }

    /// Change the contract from `date` on; history before stays untouched (§16 "Changing contract hours").
    public mutating func change(from date: LocalDate, _ update: (inout WorkSchedulePeriod) -> Void) {
        var p = period(on: date)
        update(&p)
        p.effectiveFrom = date
        if let i = periods.firstIndex(where: { $0.effectiveFrom == date }) {
            p.id = periods[i].id
            periods[i] = p
        } else {
            p.id = UUID()
            periods.append(p)
            periods.sort { $0.effectiveFrom < $1.effectiveFrom }
        }
        // Later periods keep their own values — they were explicit decisions.
    }
}

public struct OpeningBalance: Hashable, Codable, Sendable {
    public var date: LocalDate
    public var seconds: Seconds
    public init(date: LocalDate, seconds: Seconds) { self.date = date; self.seconds = seconds }
}

// MARK: Holidays & custom days (§6.8)

public struct Holiday: Hashable, Codable, Sendable {
    public var date: LocalDate
    public var name: String
    public init(date: LocalDate, name: String) { self.date = date; self.name = name }
}

/// Company-specific day off (hours = 0) or shortened day (hours > 0).
public struct CustomDay: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var date: LocalDate
    public var name: String
    public var hours: Double

    public init(id: UUID = UUID(), date: LocalDate, name: String, hours: Double = 0) {
        self.id = id; self.date = date; self.name = name; self.hours = hours
    }
}

// MARK: Absences (§6.9)

public enum AbsenceUnit: String, Codable, Sendable {
    case day
    case halfDay
    case hours
}

public enum BuiltinAbsence: String, Codable, Sendable, CaseIterable {
    case vacation
    case doctor
    case sickLeave
    case childCare
}

public struct AbsenceType: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var builtin: BuiltinAbsence?
    public var name: String
    public var unit: AbsenceUnit
    /// SF Symbol name.
    public var icon: String
    public var archived: Bool

    public init(id: UUID = UUID(), builtin: BuiltinAbsence? = nil, name: String, unit: AbsenceUnit, icon: String, archived: Bool = false) {
        self.id = id; self.builtin = builtin; self.name = name; self.unit = unit; self.icon = icon; self.archived = archived
    }

    /// Stable ids so built-in types are the same on every Mac.
    public static let vacation = AbsenceType(id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!, builtin: .vacation, name: "Vacation", unit: .day, icon: "sun.horizon")
    public static let doctor = AbsenceType(id: UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!, builtin: .doctor, name: "Doctor", unit: .hours, icon: "stethoscope")
    public static let sickLeave = AbsenceType(id: UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!, builtin: .sickLeave, name: "Sick leave", unit: .day, icon: "thermometer.medium")
    public static let childCare = AbsenceType(id: UUID(uuidString: "A0000000-0000-0000-0000-000000000004")!, builtin: .childCare, name: "Child care", unit: .day, icon: "figure.and.child.holdinghands")

    public static let builtins: [AbsenceType] = [.vacation, .doctor, .sickLeave, .childCare]
}

public struct Absence: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var typeId: UUID
    public var date: LocalDate
    public var unit: AbsenceUnit
    /// Seconds for `.hours`; ignored for day units.
    public var amountSeconds: Seconds
    /// Start time for hour-based absences (minutes after midnight), shown on the timeline.
    public var startMinutes: Int?
    public var note: String
    /// Days created together from one range share this id (edit/remove the whole range).
    public var rangeId: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), typeId: UUID, date: LocalDate, unit: AbsenceUnit, amountSeconds: Seconds = 0,
                startMinutes: Int? = nil, note: String = "", rangeId: UUID? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.typeId = typeId; self.date = date; self.unit = unit; self.amountSeconds = amountSeconds
        self.startMinutes = startMinutes; self.note = note; self.rangeId = rangeId
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    /// Whole day or half day (shown as a band), not a timed block.
    public var isAllDay: Bool { unit != .hours }
}

// MARK: Saved filters (§6.10)

public enum SuggestionSourceKind: String, Codable, Sendable {
    case jiraFilterId
    case jql
}

public struct SuggestionSource: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var instanceId: UUID
    public var kind: SuggestionSourceKind
    public var value: String
    public var name: String
    public init(id: UUID = UUID(), instanceId: UUID, kind: SuggestionSourceKind, value: String, name: String) {
        self.id = id; self.instanceId = instanceId; self.kind = kind; self.value = value; self.name = name
    }
}
