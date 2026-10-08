import Foundation

/// Minimal interface for persisting the post-login `UserSession` blob.
/// `KeychainStore` conforms (in `KeychainStore.swift`). `FileSessionStore`
/// is a dev/simulator alternative that doesn't require keychain entitlements.
public protocol SessionStore: Sendable {
    func set(_ value: String, forKey key: String) throws
    func get(key: String) throws -> String?
    func delete(key: String) throws
}

/// Plain file-based session store. Writes the value as UTF-8 to a file
/// `key`-named under `directory`.
///
/// Used in Phase 1 because the iOS Simulator rejects Keychain ops without a
/// properly signed `keychain-access-groups` entitlement (which needs a
/// development team — out of scope until Phase 3 wires signing).
///
/// Security posture:
/// - **iOS**: file is written with
///   `FileProtectionType.completeUntilFirstUserAuthentication`. Encrypted at
///   rest before the user first unlocks the device after boot; readable
///   afterwards (which is when our app cold-launches and reads the session).
///   This is the "session blob" file class — `.complete` would block
///   bootstrap restore. Phase 3 may swap this for Keychain
///   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
/// - **macOS**: macOS doesn't have iOS-style per-file data protection. The
///   directory is sandbox-private (`~/Library/Application Support/...` under
///   App Sandbox) and disk-encrypted only if the user has FileVault enabled.
///   The plaintext access token is exposed to anyone with imaging access to
///   the disk. Documented limitation; Phase 3 swaps to Keychain on Mac.
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = url(for: key)
        try value.write(to: target, atomically: true, encoding: .utf8)
        #if os(iOS)
        try (target as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
        #endif
    }

    public func get(key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        let path = url(for: key)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
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

    private func url(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }
}
