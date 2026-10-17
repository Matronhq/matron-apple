import Foundation
import os
import Security

/// The session store the apps and the share extension use: the Keychain,
/// with a file as the place an earlier version kept the session and as the
/// fallback when the Keychain can't be used.
///
/// The file only exists when it holds the newest value: a session written
/// by an earlier version, one written while the Keychain was failing, or
/// one a test rig put there. Every successful Keychain write deletes it. So:
///
/// - `get` reads the file first. If there is one, its value is copied into
///   the Keychain, the file is deleted once that write has succeeded, and
///   the value is returned. Otherwise the Keychain answers. Nobody is signed
///   out by the move, and a session saved while the Keychain was failing is
///   never shadowed by an older Keychain item.
/// - `set` writes the Keychain and deletes the file. If the Keychain write
///   fails (a build without the `keychain-access-groups` entitlement gets
///   `errSecMissingEntitlement`; a locked device, other errors) the value
///   goes to the file instead, so those builds keep working.
/// - `delete` clears both. If the Keychain item can't be deleted, the file
///   is left holding a signed-out marker instead, so the old session is not
///   restored, and the next `get` finishes the delete.
public struct MigratingSessionStore: SessionStore {
    private let keychain: any SessionStore
    private let file: any SessionStore
    private static let logger = Logger(subsystem: "chat.matron", category: "session-store")

    public init(keychain: any SessionStore, file: any SessionStore) {
        self.keychain = keychain
        self.file = file
    }

    public func get(key: String) throws -> String? {
        let fileValue: String?
        do {
            fileValue = try file.get(key: key)
        } catch {
            // Unreadable (e.g. before first unlock): the Keychain item, if
            // any, is the best answer we have.
            Self.logger.error("session file unreadable: \(error.localizedDescription, privacy: .public)")
            fileValue = nil
        }
        if fileValue == Self.signedOutMarker {
            // A sign-out whose Keychain delete failed: finish it now.
            if (try? deleteFromKeychain(key: key)) != nil { try? file.delete(key: key) }
            return nil
        }
        if let fileValue {
            do {
                try keychain.set(fileValue, forKey: key)
                try? file.delete(key: key)
            } catch {
                Self.logger.info("session stays in the file: \(Self.describe(error), privacy: .public)")
            }
            return fileValue
        }
        do {
            return try keychain.get(key: key)
        } catch {
            Self.logger.info("keychain read failed: \(Self.describe(error), privacy: .public)")
            return nil
        }
    }

    public func set(_ value: String, forKey key: String) throws {
        do {
            try keychain.set(value, forKey: key)
        } catch {
            Self.logger.info("keychain write failed, using the file: \(Self.describe(error), privacy: .public)")
            try file.set(value, forKey: key)
            return
        }
        do {
            try file.delete(key: key)
        } catch {
            // A file left behind would win the next `get`; make sure it at
            // least holds the value just saved.
            try? file.set(value, forKey: key)
        }
    }

    public func delete(key: String) throws {
        do {
            try deleteFromKeychain(key: key)
        } catch {
            // The Keychain item is still there (e.g. the device is locked).
            // Leave a marker in the file, which `get` reads first, so the
            // old session is not restored; the next read retries the delete.
            Self.logger.error("keychain delete failed, leaving a signed-out marker: \(Self.describe(error), privacy: .public)")
            try file.set(Self.signedOutMarker, forKey: key)
            return
        }
        try file.delete(key: key)
    }

    /// File content that stands for "signed out": never a valid session.
    static let signedOutMarker = ""

    /// Deletes the Keychain item. A build without Keychain access cannot
    /// have stored one, so `errSecMissingEntitlement` counts as done.
    private func deleteFromKeychain(key: String) throws {
        do {
            try keychain.delete(key: key)
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            return
        }
    }

    private static func describe(_ error: Error) -> String {
        if let status = (error as? KeychainError)?.status { return "OSStatus \(status)" }
        return error.localizedDescription
    }
}

/// Builds the session store for a process.
public enum SessionStores {
    /// The store the apps and the share extension use: Keychain first,
    /// `directory` as the legacy location and fallback (see
    /// `MigratingSessionStore`).
    ///
    /// Debug builds use the file alone in a test process, when pointed at a
    /// throwaway container (`MATRON_APP_SUPPORT_OVERRIDE`: the Mac
    /// screenshot and perf rigs), and when launched with
    /// `fileOnlyLaunchArgument` (rigs that sign the app in and out by
    /// writing and removing the session file). The Keychain item is per
    /// user, not per container: a test run would otherwise read, overwrite
    /// or delete the developer's own session (or meet a Keychain prompt),
    /// and a rig would copy its demo session over the developer's, then
    /// lose track of it. Shipping builds always use the Keychain.
    public static func live(
        directory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        isTestRun: Bool = NSClassFromString("XCTestCase") != nil
    ) -> any SessionStore {
        let file = FileSessionStore(directory: directory)
        guard usesKeychain(environment: environment, arguments: arguments, isTestRun: isTestRun) else { return file }
        return MigratingSessionStore(keychain: KeychainStore.sessionStore(), file: file)
    }

    /// Launch argument that keeps a Debug build's session in the file.
    public static let fileOnlyLaunchArgument = "-MatronSessionFile"

    static func usesKeychain(environment: [String: String], arguments: [String], isTestRun: Bool) -> Bool {
        #if DEBUG
        if isTestRun { return false }
        if let override = environment["MATRON_APP_SUPPORT_OVERRIDE"], !override.isEmpty { return false }
        if arguments.contains(fileOnlyLaunchArgument) { return false }
        #endif
        return true
    }
}
