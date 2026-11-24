import Foundation
import Testing
import TikjotDomain
import GRDB
@testable import TikjotPersistence

@Suite struct PersistenceTests {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tikjot-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func sample() -> Changes {
        var c = Changes()
        let p = Project(name: "Payments", color: "tangerine")
        let i = UUID()
        c.upsertInstances = [JiraInstance(id: i, name: "Cloud", kind: .cloud, baseURL: URL(string: "https://acme.atlassian.net")!, authMethod: .cloudApiToken, login: "me@acme.com", historyStartDate: LocalDate("2026-09-01"))]
        c.upsertProjects = [p]
        c.upsertRules = [ProjectRule(projectId: p.id, instanceId: i, value: "abc")]
        c.upsertIssues = [Issue(instanceId: i, issueId: "10001", key: "ABC-1", summary: "Gateway", sources: ["assigned"])]
        c.upsertEntries = [TimeEntry(start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_003_600), instanceId: i, issueId: "10001", projectId: p.id, description: "Work")]
        c.upsertGroups = [WorklogGroup(instanceId: i, issueId: "10001", localDate: LocalDate("2026-09-21")!, lastSent: SentSnapshot(startedAt: Date(timeIntervalSince1970: 1_790_000_000), durationSeconds: 3600, comment: "Work"), syncState: .synced)]
        c.upsertSchedule = [WorkSchedulePeriod(effectiveFrom: LocalDate("2026-01-01")!)]
        c.upsertAbsenceTypes = AbsenceType.builtins
        c.upsertAbsences = [Absence(typeId: AbsenceType.vacation.id, date: LocalDate("2026-09-22")!, unit: .day)]
        var s = AppSettings(); s.graceDays = 7
        c.settings = s
        return c
    }

    @Test func roundTripInMemory() throws {
        let db = try AppDatabase()
        try db.apply(sample())
        let s = try db.load()
        #expect(s.projects.count == 1)
        #expect(s.rules.first?.value == "ABC")
        #expect(s.issues.first?.sources == ["assigned"])
        #expect(s.groups.first?.lastSent?.durationSeconds == 3600)
        #expect(s.absenceTypes.count == 4)
        #expect(s.settings.graceDays == 7)
        #expect(s.instances.first?.historyStartDate == LocalDate("2026-09-01"))
    }

    @Test func encryptedFileNeedsKey() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("db.sqlite")
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        do {
            let db = try AppDatabase(url: url, key: key)
            try db.apply(sample())
        }
        // plaintext SQLite header must not be present
        let head = try Data(contentsOf: url).prefix(16)
        #expect(String(data: head, encoding: .utf8)?.hasPrefix("SQLite format") != true)
        // right key opens
        #expect(try AppDatabase(url: url, key: key).load().projects.count == 1)
        // wrong key fails cleanly
        #expect(throws: PersistenceError.cannotOpen) {
            _ = try AppDatabase(url: url, key: Data(repeating: 1, count: 32))
        }
    }

    @Test func snapshotIsEncryptedWithSameKey() throws {
        let dir = tempDir()
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let db = try AppDatabase(url: dir.appendingPathComponent("db.sqlite"), key: key)
        try db.apply(sample())
        let snaps = SnapshotManager(directory: dir.appendingPathComponent("snapshots"))
        let url = try #require(try snaps.takeIfNeeded(db, keep: 30))
        #expect(try snaps.takeIfNeeded(db, keep: 30) == nil) // once per day
        let restored = try AppDatabase(url: url, key: key)
        #expect(try restored.load().entries.count == 1)
    }

    @Test func snapshotKeyStaysOutOfErrorsAndSnapIsDetached() throws {
        let dir = tempDir()
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let hex = key.map { String(format: "%02x", $0) }.joined()
        let db = try AppDatabase(url: dir.appendingPathComponent("db.sqlite"), key: key)
        try db.apply(sample())
        // Destination folder doesn't exist → ATTACH fails.
        let error = try #require(throws: (any Error).self) { try db.snapshot(to: dir.appendingPathComponent("missing/snap.sqlite")) }
        for text in ["\(error)", error.localizedDescription, String(reflecting: error), SafeError.describe(error)] {
            #expect(!text.lowercased().contains(hex))
        }
        // A later snapshot still works (nothing left attached) and opens with the key, read-only.
        let url = dir.appendingPathComponent("tikjot-2026-09-21.sqlite")
        try db.snapshot(to: url)
        let mtime = try #require(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        #expect(try AppDatabase.loadSnapshot(at: url, key: key).entries.count == 1)
        #expect(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == mtime)
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        #expect(throws: PersistenceError.cannotOpen) { _ = try AppDatabase.loadSnapshot(at: url, key: Data(repeating: 1, count: 32)) }
    }

    @Test func snapshotDateComesFromName() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("tikjot-2026-09-21.sqlite")
        try Data([1]).write(to: url)
        let cal = Calendar.current
        // Touched today (not on 21 Sep): the name wins, at midnight.
        #expect(SnapshotManager.date(of: url, calendar: cal) == LocalDate("2026-09-21")!.start(in: cal))
        let noon = LocalDate("2026-09-21")!.at(minutes: 12 * 60, in: cal)
        try FileManager.default.setAttributes([.modificationDate: noon], ofItemAtPath: url.path)
        #expect(SnapshotManager.date(of: url, calendar: cal) == noon)
    }

    @Test func databaseFromPragmaKeyStillOpens() throws {
        // Files created before the key moved to sqlite3_key (PRAGMA key = "x'…'") open unchanged.
        let dir = tempDir()
        let url = dir.appendingPathComponent("db.sqlite")
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let hex = key.map { String(format: "%02x", $0) }.joined()
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA key = \"x'\(hex)'\"") }
        do {
            let q = try DatabaseQueue(path: url.path, configuration: config)
            try q.write { try $0.execute(sql: "CREATE TABLE t(x)") }
        }
        let db = try AppDatabase(url: url, key: key)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM t") } == 0)
    }

    @Test func wipeEmptiesEverything() throws {
        let dir = tempDir()
        let db = try AppDatabase(url: dir.appendingPathComponent("db.sqlite"), key: Data(repeating: 7, count: 32))
        try db.apply(sample())
        try db.setValue("x", forKey: "something")
        try db.wipe()
        let s = try db.load()
        #expect(s.entries.isEmpty && s.projects.isEmpty && s.instances.isEmpty)
        #expect(try db.value(String.self, forKey: "something") == nil)
    }

    @Test func setAsideIsEncryptedWithDatabaseKey() throws {
        let db = try AppDatabase()
        try db.apply(sample())
        let data = try db.load()
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let file = try BackupCodec.sealSetAside(data, databaseKey: key)
        #expect(file.range(of: Data("Work".utf8)) == nil)
        #expect(try BackupCodec.openSetAside(file, databaseKey: key).entries == data.entries)
        #expect(throws: PersistenceError.backupWrongPassword) { _ = try BackupCodec.openSetAside(file, databaseKey: Data(repeating: 1, count: 32)) }
    }

    @Test func backupRejectsOutOfRangeIterations() throws {
        let file = try BackupCodec.export(DataSnapshot(), password: "pw", appVersion: "1.0", iterations: 100_000)
        for bad: UInt32 in [1, 99_999, 10_000_001] {
            var f = file
            var it = bad.bigEndian
            f.replaceSubrange(9..<13, with: Data(bytes: &it, count: 4))
            #expect(throws: PersistenceError.backupCorrupt) { _ = try BackupCodec.import(f, password: "pw") }
        }
    }

    @Test func backupRoundTrip() throws {
        let db = try AppDatabase()
        try db.apply(sample())
        let data = try db.load()
        let file = try BackupCodec.export(data, password: "correct horse", appVersion: "1.0", iterations: 100_000)
        let back = try BackupCodec.import(file, password: "correct horse")
        #expect(back.data.entries == data.entries)
        #expect(throws: PersistenceError.backupWrongPassword) {
            _ = try BackupCodec.import(file, password: "wrong")
        }
        let db2 = try AppDatabase()
        try db2.replaceAll(with: back.data)
        #expect(try db2.load().projects.count == 1)
    }

    // MARK: Token expiry (v3)

    @Test func tokenExpiryRoundTripsThroughDatabaseBackupAndSetAside() throws {
        var c = sample()
        c.upsertInstances[0].tokenExpires = LocalDate("2027-10-06")
        let db = try AppDatabase()
        try db.apply(c)
        let data = try db.load()
        #expect(data.instances.first?.tokenExpires == LocalDate("2027-10-06"))
        let back = try BackupCodec.import(BackupCodec.export(data, password: "correct horse", appVersion: "1.0", iterations: 100_000), password: "correct horse")
        #expect(back.data.instances.first?.tokenExpires == LocalDate("2027-10-06"))
        let key = Data(repeating: 7, count: 32)
        #expect(try BackupCodec.openSetAside(BackupCodec.sealSetAside(data, databaseKey: key), databaseKey: key).instances.first?.tokenExpires == LocalDate("2027-10-06"))
        let db2 = try AppDatabase()
        try db2.replaceAll(with: back.data)
        #expect(try db2.load().instances.first?.tokenExpires == LocalDate("2027-10-06"))
    }

    @Test func instanceWithoutTokenExpiryDecodesAsUnknown() throws {
        // A backup made before v3 has no "tokenExpires" key.
        let i = JiraInstance(name: "Cloud", kind: .cloud, baseURL: URL(string: "https://acme.atlassian.net")!, authMethod: .cloudApiToken, login: "me@acme.com")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(i)) as! [String: Any]
        json["tokenExpires"] = nil
        let old = try JSONDecoder().decode(JiraInstance.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.tokenExpires == nil)
        #expect(old.id == i.id)
    }

    @Test func databaseBeforeV3GetsTheColumnAndKeepsConnections() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("db.sqlite")
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        do {
            let db = try AppDatabase(url: url, key: key)
            try db.apply(sample())
            // Back to the v2 schema: no column, migration not recorded.
            try db.writer.writeWithoutTransaction { db in
                try db.execute(sql: "ALTER TABLE jiraInstance DROP COLUMN tokenExpires")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v3-instance-token-expires'")
            }
        }
        let db = try AppDatabase(url: url, key: key)
        let s = try db.load()
        #expect(s.instances.count == 1)
        #expect(s.instances.first?.tokenExpires == nil)
        var inst = try #require(s.instances.first)
        inst.tokenExpires = LocalDate("2027-01-31")
        var c = Changes(); c.upsertInstances = [inst]
        try db.apply(c)
        #expect(try db.load().instances.first?.tokenExpires == LocalDate("2027-01-31"))
    }

    @Test func backupWithImpossibleTokenExpiryIsRefused() throws {
        var s = DataSnapshot()
        s.instances = [JiraInstance(name: "Cloud", kind: .cloud, baseURL: URL(string: "https://acme.atlassian.net")!, authMethod: .cloudApiToken,
                                    login: "me@acme.com", tokenExpires: LocalDate(year: 2026, month: 2, day: 31))]
        #expect(throws: PersistenceError.backupOutOfRange) { _ = try s.validated() }
    }
}
