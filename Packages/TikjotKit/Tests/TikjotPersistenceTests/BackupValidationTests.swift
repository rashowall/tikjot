import Foundation
import Testing
import TikjotDomain
@testable import TikjotPersistence

/// A crafted backup is refused instead of crashing tikjot at every launch (security round 2, S3, S11).
@Suite struct BackupValidationTests {
    func base() -> DataSnapshot {
        var s = DataSnapshot()
        s.entries = [TimeEntry(start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_003_600))]
        s.schedule = [WorkSchedulePeriod(effectiveFrom: LocalDate("2026-01-01")!)]
        return s
    }

    @Test func goodDataPassesAndSettingsAreClamped() throws {
        var s = base()
        s.settings.autoRefreshMinutes = Int.max
        let v = try s.validated()
        #expect(v.entries == s.entries)
        #expect(v.settings.autoRefreshMinutes == 240)
    }

    @Test func outOfRangeValuesAreRefused() {
        var bad: [DataSnapshot] = []
        var s = base(); s.entries[0].start = Date(timeIntervalSinceReferenceDate: 1e15); bad.append(s)
        s = base(); s.entries[0].end = s.entries[0].start.addingTimeInterval(49 * 3600); bad.append(s)
        s = base(); s.schedule[0].dailyHours = .nan; bad.append(s)
        s = base(); s.schedule[0].workdayEnd = Int.max; bad.append(s)
        s = base(); s.groups = [WorklogGroup(instanceId: UUID(), issueId: "1", localDate: LocalDate("2026-01-01")!, sentRaw: Int.max)]; bad.append(s)
        s = base(); s.absences = [Absence(typeId: UUID(), date: LocalDate("2026-01-01")!, unit: .hours, amountSeconds: Int.max)]; bad.append(s)
        for b in bad {
            #expect(throws: PersistenceError.backupOutOfRange) { _ = try b.validated() }
        }
    }

    @Test func importRunsTheValidation() throws {
        var s = base()
        s.entries[0].end = s.entries[0].start.addingTimeInterval(72 * 3600)
        let file = try BackupCodec.export(s, password: "pw", appVersion: "1.0", iterations: 100_000)
        #expect(throws: PersistenceError.backupOutOfRange) { _ = try BackupCodec.import(file, password: "pw") }
    }

    @Test func unknownVersionIsRefused() throws {
        var file = try BackupCodec.export(DataSnapshot(), password: "pw", appVersion: "1.0", iterations: 100_000)
        file[8] = 2
        #expect(throws: PersistenceError.backupCorrupt) { _ = try BackupCodec.import(file, password: "pw") }
    }
}

@Suite struct InstanceDeletionTests {
    @Test func deletingAConnectionRemovesItsSavedFilters() throws {
        let db = try AppDatabase()
        let a = JiraInstance(name: "A", kind: .cloud, baseURL: URL(string: "https://a.atlassian.net")!, authMethod: .cloudApiToken, login: "me")
        let b = JiraInstance(name: "B", kind: .cloud, baseURL: URL(string: "https://b.atlassian.net")!, authMethod: .cloudApiToken, login: "me")
        var c = Changes()
        c.upsertInstances = [a, b]
        c.upsertSuggestionSources = [SuggestionSource(instanceId: a.id, kind: .jql, value: "project = SECRET", name: "Secret"),
                                     SuggestionSource(instanceId: b.id, kind: .jql, value: "project = KEEP", name: "Keep")]
        try db.apply(c)
        c = Changes(); c.deleteInstances = [a.id]
        try db.apply(c)
        #expect(try db.load().suggestionSources.map(\.name) == ["Keep"])
    }
}
