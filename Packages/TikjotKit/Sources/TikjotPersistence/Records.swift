import Foundation
import GRDB
import TikjotDomain

// Domain types are stored as GRDB records directly (Codable columns; nested values as JSON).

extension JiraInstance: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "jiraInstance"
}

extension Project: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "project"
}

extension ProjectRule: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "projectRule"
}

extension Issue: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "issue"
}

extension TimeEntry: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "timeEntry"
}

extension WorklogGroup: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "worklogGroup"
}

extension WorkSchedulePeriod: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "workSchedulePeriod"
}

extension CustomDay: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "customDay"
}

extension AbsenceType: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "absenceType"
}

extension Absence: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "absence"
}

extension SuggestionSource: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "suggestionSource"
}

/// Key/value store for settings and small app state (JSON values).
struct KeyValue: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "keyValue"
    var key: String
    var value: Data
}
