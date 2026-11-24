import Foundation
import GRDB
import TikjotDomain

public enum PersistenceError: Error, Equatable, Sendable {
    /// The database exists but the key does not open it (Keychain key missing or wrong).
    case cannotOpen
    case backupWrongPassword
    case backupCorrupt
    /// The backup opens but holds values tikjot can't use (dates outside 1900–2200, entries of 48 h or more, …).
    case backupOutOfRange
    /// The SQLite library in use is not SQLCipher: never run unencrypted.
    case notEncrypted
}

/// Error text safe for logs and UI: result codes and types only. GRDB's `DatabaseError.description`
/// carries the SQL text, so it never goes out raw.
public enum SafeError {
    public static func describe(_ error: Error) -> String {
        switch error {
        case let e as DatabaseError: "SQLite error \(e.extendedResultCode.rawValue)"
        case let e as PersistenceError: "PersistenceError.\(e)"
        default: "\(type(of: error)) \((error as NSError).domain) \((error as NSError).code)"
        }
    }
}

/// Everything the app keeps, loaded at once (the data set is small: years of entries are a few MB).
public struct DataSnapshot: Codable, Sendable, Equatable {
    public var instances: [JiraInstance] = []
    public var projects: [Project] = []
    public var rules: [ProjectRule] = []
    public var issues: [Issue] = []
    public var entries: [TimeEntry] = []
    public var groups: [WorklogGroup] = []
    public var schedule: [WorkSchedulePeriod] = []
    public var customDays: [CustomDay] = []
    public var absenceTypes: [AbsenceType] = []
    public var absences: [Absence] = []
    public var suggestionSources: [SuggestionSource] = []
    public var settings: AppSettings = AppSettings()

    public init() {}
}

/// A batch of writes applied in one transaction.
public struct Changes: Sendable {
    public var upsertInstances: [JiraInstance] = []
    public var deleteInstances: [UUID] = []
    public var upsertProjects: [Project] = []
    public var deleteProjects: [UUID] = []
    public var upsertRules: [ProjectRule] = []
    public var deleteRules: [UUID] = []
    public var upsertIssues: [Issue] = []
    public var upsertEntries: [TimeEntry] = []
    public var deleteEntries: [UUID] = []
    public var upsertGroups: [WorklogGroup] = []
    public var deleteGroups: [UUID] = []
    public var upsertSchedule: [WorkSchedulePeriod] = []
    public var deleteSchedule: [UUID] = []
    public var upsertCustomDays: [CustomDay] = []
    public var deleteCustomDays: [UUID] = []
    public var upsertAbsenceTypes: [AbsenceType] = []
    public var upsertAbsences: [Absence] = []
    public var deleteAbsences: [UUID] = []
    public var upsertSuggestionSources: [SuggestionSource] = []
    public var deleteSuggestionSources: [UUID] = []
    public var settings: AppSettings?

    public init() {}

    public var isEmpty: Bool {
        upsertInstances.isEmpty && deleteInstances.isEmpty && upsertProjects.isEmpty && deleteProjects.isEmpty
            && upsertRules.isEmpty && deleteRules.isEmpty && upsertIssues.isEmpty && upsertEntries.isEmpty
            && deleteEntries.isEmpty && upsertGroups.isEmpty && deleteGroups.isEmpty && upsertSchedule.isEmpty
            && deleteSchedule.isEmpty && upsertCustomDays.isEmpty && deleteCustomDays.isEmpty
            && upsertAbsenceTypes.isEmpty && upsertAbsences.isEmpty && deleteAbsences.isEmpty
            && upsertSuggestionSources.isEmpty && deleteSuggestionSources.isEmpty && settings == nil
    }
}

/// The encrypted SQLite database (SQLCipher, AES-256; SPEC §13).
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public let url: URL?
    private let keyHex: String?

    /// Opens (or creates) the database at `url`, encrypted with `key` (32 random bytes from the Keychain).
    public init(url: URL, key: Data) throws {
        let hex = key.map { String(format: "%02x", $0) }.joined()
        do {
            let pool = try DatabasePool(path: url.path, configuration: Self.configuration(hex: hex, readonly: false))
            // Fails here when the key is wrong.
            try Self.check(pool)
            self.writer = pool
        } catch let e as DatabaseError where e.resultCode == .SQLITE_NOTADB {
            throw PersistenceError.cannotOpen
        }
        self.url = url
        self.keyHex = hex
        try migrator.migrate(writer)
    }

    /// In-memory database for tests and previews.
    public init() throws {
        writer = try DatabaseQueue()
        url = nil
        keyHex = nil
        try migrator.migrate(writer)
    }

    private init(readOnly writer: DatabaseQueue) {
        self.writer = writer
        url = nil
        keyHex = nil
    }

    private static func configuration(hex: String, readonly: Bool) -> Configuration {
        var config = Configuration()
        config.readonly = readonly
        config.prepareDatabase { db in
            // Raw key (no PBKDF2 on every open): x'…' syntax, handed to sqlite3_key — never in SQL text.
            var raw = Data("x'\(hex)'".utf8)
            defer { raw.resetBytes(in: 0..<raw.count) }
            try db.usePassphrase(raw)
            // Deleted rows are overwritten, not left behind in free pages.
            if !readonly { try db.execute(sql: "PRAGMA secure_delete = ON") }
        }
        config.label = "tikjot"
        return config
    }

    /// The key opens the file, and the library really is SQLCipher (an empty cipher_version means plain SQLite).
    private static func check(_ reader: any DatabaseReader) throws {
        try reader.read { db in
            _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
            guard let v = try String.fetchOne(db, sql: "PRAGMA cipher_version"), !v.isEmpty else { throw PersistenceError.notEncrypted }
        }
    }

    /// Reads a snapshot without changing it (no WAL switch, no migrations, mtime kept). A snapshot
    /// from an older schema is migrated in a temporary copy that is removed afterwards.
    public static func loadSnapshot(at url: URL, key: Data) throws -> DataSnapshot {
        let hex = key.map { String(format: "%02x", $0) }.joined()
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: configuration(hex: hex, readonly: true))
            try check(queue)
        } catch let e as DatabaseError where e.resultCode == .SQLITE_NOTADB {
            throw PersistenceError.cannotOpen
        }
        let db = AppDatabase(readOnly: queue)
        if try queue.read({ try db.migrator.hasCompletedMigrations($0) }) { return try db.load() }
        try queue.close()
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("tikjot-snapshot-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: tmp.path + s) } }
        try fm.copyItem(at: url, to: tmp)
        return try AppDatabase(url: tmp, key: key).load()
    }

    /// "Delete everything": empty every table, then compact and truncate the WAL so nothing is left in free pages.
    public func wipe() throws {
        try replaceAll(with: DataSnapshot())
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM \(KeyValue.databaseTableName)")
            try db.execute(sql: "VACUUM")
            if url != nil { try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        }
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "jiraInstance") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("baseURL", .text).notNull()
                t.column("authMethod", .text).notNull()
                t.column("login", .text).notNull()
                t.column("accountId", .text)
                t.column("displayName", .text)
                t.column("jiraTimeZone", .text)
                t.column("status", .text).notNull()
                t.column("successorOf", .text)
                t.column("successionDate", .text)
                t.column("lastSyncAt", .datetime)
                t.column("syncCursor", .datetime)
                t.column("historyStartDate", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("color", .text).notNull()
                t.column("billable", .boolean).notNull()
                t.column("excludeFromWorked", .boolean).notNull()
                t.column("archived", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(table: "projectRule") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull().indexed()
                t.column("type", .text).notNull()
                t.column("instanceId", .text).notNull()
                t.column("value", .text).notNull()
                t.column("priority", .integer).notNull()
                t.uniqueKey(["type", "instanceId", "value"])
            }
            try db.create(table: "issue") { t in
                t.column("instanceId", .text).notNull()
                t.column("issueId", .text).notNull()
                t.column("key", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("issueType", .text)
                t.column("statusName", .text)
                t.column("statusCategory", .text).notNull()
                t.column("parentKey", .text)
                t.column("parentSummary", .text)
                t.column("assignedToMe", .boolean).notNull()
                t.column("originalEstimateSeconds", .integer)
                t.column("timeSpentSeconds", .integer)
                t.column("updated", .datetime)
                t.column("availability", .text).notNull()
                t.column("pinned", .boolean).notNull()
                t.column("pinOrder", .integer).notNull()
                t.column("fetchedAt", .datetime).notNull()
                t.column("sources", .jsonText).notNull()
                t.primaryKey(["instanceId", "issueId"])
            }
            try db.create(table: "timeEntry") { t in
                t.primaryKey("id", .text)
                t.column("start", .datetime).notNull().indexed()
                t.column("end", .datetime)
                t.column("instanceId", .text)
                t.column("issueId", .text)
                t.column("projectId", .text)
                t.column("description", .text).notNull()
                t.column("source", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("worklogGroupId", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(table: "worklogGroup") { t in
                t.primaryKey("id", .text)
                t.column("instanceId", .text).notNull()
                t.column("issueId", .text).notNull()
                t.column("localDate", .text).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("remoteWorklogId", .text)
                t.column("remoteUpdated", .datetime)
                t.column("lastSent", .jsonText)
                t.column("sentRaw", .integer)
                t.column("remoteVersion", .jsonText)
                t.column("syncState", .text).notNull()
                t.column("lastError", .jsonText)
                t.column("commentOverride", .text)
                t.column("commentOverrideStale", .boolean).notNull()
                t.column("changedInJiraWas", .integer)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(table: "workSchedulePeriod") { t in
                t.primaryKey("id", .text)
                t.column("effectiveFrom", .text).notNull()
                t.column("dailyHours", .double).notNull()
                t.column("workdays", .jsonText).notNull()
                t.column("workdayStart", .integer).notNull()
                t.column("workdayEnd", .integer).notNull()
            }
            try db.create(table: "customDay") { t in
                t.primaryKey("id", .text)
                t.column("date", .text).notNull()
                t.column("name", .text).notNull()
                t.column("hours", .double).notNull()
            }
            try db.create(table: "absenceType") { t in
                t.primaryKey("id", .text)
                t.column("builtin", .text)
                t.column("name", .text).notNull()
                t.column("unit", .text).notNull()
                t.column("icon", .text).notNull()
                t.column("archived", .boolean).notNull()
            }
            try db.create(table: "absence") { t in
                t.primaryKey("id", .text)
                t.column("typeId", .text).notNull()
                t.column("date", .text).notNull().indexed()
                t.column("unit", .text).notNull()
                t.column("amountSeconds", .integer).notNull()
                t.column("startMinutes", .integer)
                t.column("note", .text).notNull()
                t.column("rangeId", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(table: "suggestionSource") { t in
                t.primaryKey("id", .text)
                t.column("instanceId", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("value", .text).notNull()
                t.column("name", .text).notNull()
            }
            try db.create(table: "keyValue") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob).notNull()
            }
        }
        m.registerMigration("v2-issue-project-name") { db in
            try db.alter(table: "issue") { t in t.add(column: "projectName", .text) }
        }
        // Cloud API token expiry (LocalDate as "yyyy-MM-dd"); existing connections get NULL = unknown, no warning.
        m.registerMigration("v3-instance-token-expires") { db in
            try db.alter(table: "jiraInstance") { t in t.add(column: "tokenExpires", .text) }
        }
        return m
    }

    // MARK: Reading

    public func load() throws -> DataSnapshot {
        try writer.read { db in
            var s = DataSnapshot()
            s.instances = try JiraInstance.fetchAll(db)
            s.projects = try Project.fetchAll(db)
            s.rules = try ProjectRule.fetchAll(db)
            s.issues = try Issue.fetchAll(db)
            s.entries = try TimeEntry.filter(Column("deletedAt") == nil).order(Column("start")).fetchAll(db)
            s.groups = try WorklogGroup.fetchAll(db)
            s.schedule = try WorkSchedulePeriod.fetchAll(db)
            s.customDays = try CustomDay.fetchAll(db)
            s.absenceTypes = try AbsenceType.fetchAll(db)
            s.absences = try Absence.filter(Column("deletedAt") == nil).fetchAll(db)
            s.suggestionSources = try SuggestionSource.fetchAll(db)
            if let kv = try KeyValue.fetchOne(db, key: "settings") {
                s.settings = ((try? JSONDecoder().decode(AppSettings.self, from: kv.value)) ?? AppSettings()).clamped()
            }
            return s
        }
    }

    // MARK: Writing

    public func apply(_ c: Changes) throws {
        guard !c.isEmpty else { return }
        try writer.write { db in
            try Self.apply(c, db)
        }
    }

    static func apply(_ c: Changes, _ db: Database) throws {
        for x in c.upsertInstances { try x.upsert(db) }
        for id in c.deleteInstances {
            _ = try JiraInstance.deleteOne(db, key: id)
            try db.execute(sql: "DELETE FROM issue WHERE instanceId = ?", arguments: [id])
            // Its saved filters / JQL go with it (they name its projects and tasks).
            try db.execute(sql: "DELETE FROM suggestionSource WHERE instanceId = ?", arguments: [id])
        }
        for x in c.upsertProjects { try x.upsert(db) }
        for id in c.deleteProjects { _ = try Project.deleteOne(db, key: id) }
        for id in c.deleteRules { _ = try ProjectRule.deleteOne(db, key: id) }
        for x in c.upsertRules {
            // A key belongs to one project only: the newest rule wins.
            try db.execute(sql: "DELETE FROM projectRule WHERE type = ? AND instanceId = ? AND value = ? AND id != ?",
                           arguments: [x.type.rawValue, x.instanceId, x.value, x.id])
            try x.upsert(db)
        }
        for x in c.upsertIssues { try x.upsert(db) }
        for x in c.upsertEntries { try x.upsert(db) }
        for id in c.deleteEntries { _ = try TimeEntry.deleteOne(db, key: id) }
        for x in c.upsertGroups { try x.upsert(db) }
        for id in c.deleteGroups { _ = try WorklogGroup.deleteOne(db, key: id) }
        for x in c.upsertSchedule { try x.upsert(db) }
        for id in c.deleteSchedule { _ = try WorkSchedulePeriod.deleteOne(db, key: id) }
        for x in c.upsertCustomDays { try x.upsert(db) }
        for id in c.deleteCustomDays { _ = try CustomDay.deleteOne(db, key: id) }
        for x in c.upsertAbsenceTypes { try x.upsert(db) }
        for x in c.upsertAbsences { try x.upsert(db) }
        for id in c.deleteAbsences { _ = try Absence.deleteOne(db, key: id) }
        for x in c.upsertSuggestionSources { try x.upsert(db) }
        for id in c.deleteSuggestionSources { _ = try SuggestionSource.deleteOne(db, key: id) }
        if let s = c.settings {
            try KeyValue(key: "settings", value: JSONEncoder().encode(s)).upsert(db)
        }
    }

    /// Replaces everything (restore from backup).
    public func replaceAll(with s: DataSnapshot) throws {
        try writer.write { db in
            for table in ["jiraInstance", "project", "projectRule", "issue", "timeEntry", "worklogGroup",
                          "workSchedulePeriod", "customDay", "absenceType", "absence", "suggestionSource", "keyValue"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            var c = Changes()
            c.upsertInstances = s.instances
            c.upsertProjects = s.projects
            c.upsertRules = s.rules
            c.upsertIssues = s.issues
            c.upsertEntries = s.entries
            c.upsertGroups = s.groups
            c.upsertSchedule = s.schedule
            c.upsertCustomDays = s.customDays
            c.upsertAbsenceTypes = s.absenceTypes
            c.upsertAbsences = s.absences
            c.upsertSuggestionSources = s.suggestionSources
            c.settings = s.settings
            try Self.apply(c, db)
        }
    }

    // MARK: App state values

    public func value<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        try writer.read { db in
            guard let kv = try KeyValue.fetchOne(db, key: key) else { return nil }
            return try JSONDecoder().decode(T.self, from: kv.value)
        }
    }

    public func setValue<T: Encodable>(_ value: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(value)
        try writer.write { db in try KeyValue(key: key, value: data).upsert(db) }
    }

    // MARK: Snapshots (§13: daily encrypted copies, keep last N)

    /// Copies the database to `destination`, encrypted with the same key (`sqlcipher_export`).
    public func snapshot(to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        let hex = keyHex
        try writer.writeWithoutTransaction { db in
            if let hex {
                // The key is a bound argument (never in SQL text, so never in error descriptions), and snap
                // is always detached: a failed export must not leave it attached for the next attempt.
                try db.execute(sql: "ATTACH DATABASE ? AS snap KEY ?", arguments: [destination.path, "x'\(hex)'"])
                defer { try? db.execute(sql: "DETACH DATABASE snap") }
                try db.execute(sql: "SELECT sqlcipher_export('snap')")
            } else {
                try db.execute(sql: "VACUUM INTO ?", arguments: [destination.path])
            }
        }
    }
}
