import Foundation
import Security

/// Secrets live only in the Keychain (§13): the database key and Jira tokens.
enum Keychain {
    /// The app's own bundle ID: Release stays "com.tikjot.mac" (existing items), Debug is "com.tikjot.mac.dev".
    static let service = Bundle.main.bundleIdentifier ?? "com.tikjot.mac"

    enum Failure: Error {
        case status(OSStatus)
        /// The Keychain answered with an error (locked, denied…), not "no such item".
        case unavailable(OSStatus)
    }

    enum Lookup {
        case found(Data)
        case notFound
        case failed(OSStatus)
    }

    /// Only `errSecItemNotFound` means missing; any other error must never be taken as "no key".
    static func lookup(_ account: String) -> Lookup {
        var failure: OSStatus?
        for dp in [true, false] {
            var q = base(account, dataProtection: dp)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            let s = SecItemCopyMatching(q as CFDictionary, &out)
            switch s {
            case errSecSuccess:
                if let d = out as? Data { return .found(d) }
                failure = s
            case errSecItemNotFound, errSecMissingEntitlement: continue
            default: failure = s
            }
        }
        return failure.map { .failed($0) } ?? .notFound
    }

    static func read(_ account: String) -> Data? {
        if case .found(let d) = lookup(account) { return d }
        return nil
    }

    /// Updates in place when the item exists, so a failed add never leaves the account empty.
    static func write(_ data: Data, account: String) throws {
        for dp in [true, false] {
            if SecItemUpdate(base(account, dataProtection: dp) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return }
        }
        var status: OSStatus = errSecSuccess
        for dp in [true, false] {
            var q = base(account, dataProtection: dp)
            q[kSecValueData as String] = data
            if dp { q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
            status = SecItemAdd(q as CFDictionary, nil)
            if status == errSecSuccess { return }
            // -34018: data-protection keychain needs entitlements we may not have → classic keychain.
            if status != errSecMissingEntitlement { break }
        }
        throw Failure.status(status)
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        var ok = false
        for dp in [true, false] {
            if SecItemDelete(base(account, dataProtection: dp) as CFDictionary) == errSecSuccess { ok = true }
        }
        return ok
    }

    /// Every item of this service except `keep` — including tokens of connections tikjot no longer knows about.
    static func deleteAll(except keep: Set<String>) {
        for dp in [true, false] {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            if dp { q[kSecUseDataProtectionKeychain as String] = true }
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { continue }
            for account in Set(items.compactMap { $0[kSecAttrAccount as String] as? String }) where !keep.contains(account) {
                SecItemDelete(base(account, dataProtection: dp) as CFDictionary)
            }
        }
    }

    private static func base(_ account: String, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    // MARK: Named items

    static let databaseKeyAccount = "database-key"
    static func jiraAccount(_ id: UUID) -> String { "jira-\(id.uuidString)" }

    /// A fresh database key. An existing key is never lost: it is first kept as `database-key-<stamp>`
    /// (the stamp of the files set aside with it), and a Keychain error stops here instead of passing for "no key".
    static func newDatabaseKey(archivingAs stamp: Int = Int(Date().timeIntervalSince1970)) throws -> Data {
        switch lookup(databaseKeyAccount) {
        case .found(let old): try write(old, account: "\(databaseKeyAccount)-\(stamp)")
        case .notFound: break
        case .failed(let s): throw Failure.unavailable(s)
        }
        var key = Data(count: 32)
        let s = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard s == errSecSuccess else { throw Failure.status(s) }
        try write(key, account: databaseKeyAccount)
        return key
    }
}

enum Paths {
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tikjot", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var database: URL { support.appendingPathComponent("tikjot.sqlite") }
    static var snapshots: URL { support.appendingPathComponent("Snapshots", isDirectory: true) }
    static var setAside: URL { support.appendingPathComponent("Set aside", isDirectory: true) }
    static var logs: URL {
        let u = support.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
