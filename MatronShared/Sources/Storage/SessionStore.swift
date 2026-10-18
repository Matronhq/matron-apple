import Foundation

/// Minimal interface for persisting the post-login `UserSession` blob.
///
/// The apps and the iOS share extension get theirs from
/// `SessionStores.live(directory:)`: the session lives in the Keychain
/// (`KeychainStore.sessionStore()`), with `FileSessionStore` as the legacy
/// location it is migrated from and the fallback for builds that cannot use
/// the Keychain. See `MigratingSessionStore`.
public protocol SessionStore: Sendable {
    func set(_ value: String, forKey key: String) throws
    func get(key: String) throws -> String?
    func delete(key: String) throws
}

/// Plain file-based session store. Writes the value as UTF-8 to a file
/// `key`-named under `directory`.
///
/// No longer the primary home of the session: `MigratingSessionStore` reads
/// a file left here by an earlier version into the Keychain and deletes it,
/// and writes here only when the Keychain is unusable (a build without the
/// `keychain-access-groups` entitlement: unsigned Simulator builds, the
/// ad-hoc signed Mac build), and test runs use it on its own.
///
/// Protection of the file:
/// - `directory` is excluded from backups (iCloud / Finder backups on iOS,
///   Time Machine on macOS), so a session never travels to another device
///   or an old backup.
/// - **iOS**: file is written with
///   `FileProtectionType.completeUntilFirstUserAuthentication`. Encrypted at
///   rest before the user first unlocks the device after boot; readable
///   afterwards (which is when our app cold-launches and reads the session).
///   `.complete` would block bootstrap restore.
/// - **macOS**: no per-file data protection, so the file is owner-only
///   (0600) inside an owner-only (0700) directory.
///
/// Thread safety: an internal lock serialises set/get/delete so concurrent
/// callers can't tear the directory + file pair. `@unchecked Sendable`
/// because `NSLock` is not itself Sendable but the lock-protected access
/// pattern is correct.
public struct FileSessionStore: SessionStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    public func set(_ value: String, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try prepareDirectory()
        let target = url(for: key)
        try value.write(to: target, atomically: true, encoding: .utf8)
        #if os(iOS)
        try (target as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
        #elseif os(macOS)
        try FileManager.default.setAttributes([.posixPermissions: Self.filePermissions], ofItemAtPath: target.path)
        #endif
    }

    public func get(key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        let path = url(for: key)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        #if os(macOS)
        // A file written by an earlier version has default permissions;
        // tighten it on the first read rather than waiting for a write.
        try? FileManager.default.setAttributes([.posixPermissions: Self.filePermissions], ofItemAtPath: path.path)
        #endif
        return try String(contentsOf: path, encoding: .utf8)
    }

    public func delete(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let path = url(for: key)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    #if os(macOS)
    static let filePermissions = 0o600
    static let directoryPermissions = 0o700
    #endif

    /// Creates `directory` if needed, excludes it from backups and, on
    /// macOS, makes it owner-only. Runs on every write, so a directory made
    /// by an earlier version is brought into line too.
    private func prepareDirectory() throws {
        let fileManager = FileManager.default
        #if os(macOS)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: Self.directoryPermissions])
        try fileManager.setAttributes([.posixPermissions: Self.directoryPermissions], ofItemAtPath: directory.path)
        #else
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        try excluded.setResourceValues(values)
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }
}
