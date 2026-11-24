import CommonCrypto
import CryptoKit
import Foundation
import TikjotDomain

/// Encrypted export (`.tikjotbackup`, SPEC §13): full data as JSON, AES-GCM with a key derived
/// from the user's password (PBKDF2-SHA256, 600 000 iterations, random salt). Credentials are not included.
public enum BackupCodec {
    static let magic = Data("TIKJOTBK".utf8)
    static let version: UInt8 = 1
    public static let iterations: UInt32 = 600_000
    static let acceptedIterations: ClosedRange<UInt32> = 100_000...10_000_000

    public struct Payload: Codable, Sendable {
        public var createdAt: Date
        public var appVersion: String
        public var data: DataSnapshot
    }

    public static func export(_ data: DataSnapshot, password: String, appVersion: String, iterations: UInt32 = iterations) throws -> Data {
        let payload = Payload(createdAt: Date(), appVersion: appVersion, data: data)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        let plain = try encoder.encode(payload)
        var salt = Data(count: 16)
        let rng = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        // Never encrypt with a predictable (all-zero) salt.
        guard rng == errSecSuccess else { throw PersistenceError.backupCorrupt }
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plain, using: key)
        var out = magic
        out.append(version)
        var it = iterations.bigEndian
        out.append(Data(bytes: &it, count: 4))
        out.append(salt)
        out.append(sealed.combined!)
        return out
    }

    public static func `import`(_ file: Data, password: String) throws -> Payload {
        let header = magic.count + 1 + 4 + 16
        guard file.count > header, file.prefix(magic.count) == magic, file[file.startIndex + magic.count] == version else {
            throw PersistenceError.backupCorrupt
        }
        var i = magic.count + 1
        let iterations = file.subdata(in: i..<(i + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        // A crafted file must not pick a trivial (or endless) key derivation.
        guard acceptedIterations.contains(iterations) else { throw PersistenceError.backupCorrupt }
        i += 4
        let salt = file.subdata(in: i..<(i + 16))
        i += 16
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(combined: file.subdata(in: i..<file.count))
            plain = try AES.GCM.open(box, using: key)
        } catch {
            throw PersistenceError.backupWrongPassword
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        var payload: Payload
        do { payload = try decoder.decode(Payload.self, from: plain) } catch { throw PersistenceError.backupCorrupt }
        payload.data = try payload.data.validated()
        return payload
    }

    // MARK: Set aside (entries a snapshot restore moved out of the way)

    static let setAsideMagic = Data("TIKJOTSA".utf8)

    /// Encrypted with a key derived (HKDF-SHA256) from the database key: as private as the database itself.
    public static func sealSetAside(_ data: DataSnapshot, databaseKey: Data) throws -> Data {
        let sealed = try AES.GCM.seal(JSONEncoder().encode(data), using: setAsideKey(databaseKey))
        return setAsideMagic + sealed.combined!
    }

    public static func openSetAside(_ file: Data, databaseKey: Data) throws -> DataSnapshot {
        guard file.count > setAsideMagic.count, file.prefix(setAsideMagic.count) == setAsideMagic else { throw PersistenceError.backupCorrupt }
        let plain: Data
        do {
            plain = try AES.GCM.open(AES.GCM.SealedBox(combined: file.dropFirst(setAsideMagic.count)), using: setAsideKey(databaseKey))
        } catch { throw PersistenceError.backupWrongPassword }
        do { return try JSONDecoder().decode(DataSnapshot.self, from: plain) } catch { throw PersistenceError.backupCorrupt }
    }

    private static func setAsideKey(_ databaseKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: databaseKey), info: Data("tikjot set-aside v1".utf8), outputByteCount: 32)
    }

    static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var derived = Data(count: 32)
        let pw = Array(password.utf8)
        let status = derived.withUnsafeMutableBytes { d in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     d.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        guard status == kCCSuccess else { throw PersistenceError.backupCorrupt }
        return SymmetricKey(data: derived)
    }
}

/// Daily local snapshots in Application Support (encrypted with the DB key, keep last N).
public struct SnapshotManager: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public struct Info: Hashable, Sendable {
        public let url: URL
        public let date: Date
        public let size: Int64
    }

    public func list() -> [Info] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }
        return files.filter { $0.pathExtension == "sqlite" }.compactMap { u in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey])
            return Info(url: u, date: Self.date(of: u), size: Int64(v?.fileSize ?? 0))
        }.sorted { $0.date > $1.date }
    }

    /// When a snapshot was taken: the day from its name (tikjot-YYYY-MM-DD.sqlite), the time from its mtime
    /// when that is still the same day (anything that touched the file later only moves it to midnight).
    public static func date(of url: URL, calendar: Calendar = .gregorianCurrent) -> Date {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("tikjot-"), let day = LocalDate(String(name.dropFirst("tikjot-".count))) else { return mtime ?? .distantPast }
        if let mtime, LocalDate(mtime, calendar: calendar) == day { return mtime }
        return day.start(in: calendar)
    }

    /// Takes today's snapshot if there is none yet. Returns the new snapshot or nil when skipped.
    @discardableResult
    public func takeIfNeeded(_ db: AppDatabase, keep: Int, now: Date = Date(), calendar: Calendar = .gregorianCurrent) throws -> URL? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let today = LocalDate(now, calendar: calendar)
        if let last = list().first, LocalDate(last.date, calendar: calendar) == today { return nil }
        let url = directory.appendingPathComponent("tikjot-\(today.description).sqlite")
        try db.snapshot(to: url)
        prune(keep: keep)
        return url
    }

    public func prune(keep: Int) {
        for old in list().dropFirst(max(1, keep)) { try? FileManager.default.removeItem(at: old.url) }
    }
}
