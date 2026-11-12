import Foundation
import Security
import os

/// Removes what the Matrix-based builds of the apps left on the device.
///
/// Before the apps spoke the journal protocol they ran on the Matrix SDK,
/// and installs that ran those builds still hold data nothing reads any
/// more:
///
/// - the SDK's store (`sdk-store`) and the `crypto-store` folder in the
///   app's container (the App Group container on iOS, Application Support
///   on the Mac). They held the SDK's SQLite databases and encryption keys;
/// - the SDK's rotated trace logs (`matron-sdk-trace` in Caches);
/// - the recovery key, a synchronizable Keychain item under the service
///   `chat.matron.recovery`, one account per user
///   (`matron.recovery-key.<user id>`). It rides iCloud Keychain, so a
///   delete here also removes the copy on the user's other devices;
/// - the per-user "verification done" flags in `UserDefaults`
///   (`matron.verify-done.<user id>`).
///
/// It runs once per install, gated by `doneKey`, and only names things no
/// current build writes: the journal database, the signed-in session and
/// its Keychain item, and current settings are never touched. It never
/// blocks launch or throws: failures are logged and dropped, and file and
/// Keychain work runs off the main thread.
///
/// It holds every name it needs as a literal rather than reaching for the
/// symbols that once defined them, so it keeps working as those go.
public enum LegacyMatrixDataCleanup {
    /// Set in `UserDefaults.standard` once the clean-up has run.
    public static let doneKey = "matron.legacy-matrix-cleanup.done"

    /// Folders the Matrix SDK kept in the app's container.
    static let containerFolderNames = ["sdk-store", "crypto-store"]
    /// The SDK's trace-log folder in Caches.
    static let cachesFolderName = "matron-sdk-trace"
    /// Prefix of the per-user "verification done" flags.
    static let verifyDonePrefix = "matron.verify-done."
    /// Keychain service of the recovery key (every account under it).
    static let recoveryKeychainService = "chat.matron.recovery"

    private static let logger = Logger(subsystem: "chat.matron", category: "legacy-cleanup")

    /// Deletes every generic-password item under a Keychain service and
    /// returns the last status. A seam so tests need no real Keychain.
    public struct KeychainEraser: Sendable {
        public let deleteService: @Sendable (String) -> OSStatus

        public init(deleteService: @escaping @Sendable (String) -> OSStatus) {
            self.deleteService = deleteService
        }

        /// The real Keychain. Matches synchronizable and local items alike
        /// (`kSecAttrSynchronizableAny`) and names no access group, so it
        /// searches every group the app is entitled to: the recovery key
        /// was written without one, into the first (and only)
        /// `keychain-access-groups` entry, which both apps still declare.
        /// On the Mac it asks the data-protection keychain, where
        /// synchronizable items always live.
        public static let live = KeychainEraser { service in
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            ]
            #if os(macOS)
            query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue!
            #endif
            // One call removes every match; loop a few times in case a
            // platform removes only the first.
            var status = SecItemDelete(query as CFDictionary)
            var rounds = 1
            while status == errSecSuccess, rounds < 8 {
                status = SecItemDelete(query as CFDictionary)
                rounds += 1
            }
            return status
        }
    }

    /// Runs the clean-up once per install. Call it early at launch, from
    /// the main thread. The defaults part is quick and runs at once; the
    /// files and the Keychain item go on a background task, which sets
    /// `doneKey` when it finishes.
    public static func runOnceAtLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        removeVerifyDoneFlags(from: defaults)
        let folders = liveFolders()
        Task.detached(priority: .utility) {
            let foldersDone = removeFolders(folders)
            let keychainDone = removeKeychainItems(using: .live)
            if foldersDone && keychainDone {
                UserDefaults.standard.set(true, forKey: doneKey)
                logger.info("legacy Matrix data clean-up done")
            }
        }
    }

    /// The whole clean-up, synchronously, for tests. Returns whether it
    /// finished (and so set `doneKey`); `false` only when the Keychain was
    /// locked, so the next launch tries again.
    @discardableResult
    static func run(folders: [URL], defaults: UserDefaults, keychain: KeychainEraser) -> Bool {
        guard !defaults.bool(forKey: doneKey) else { return true }
        removeVerifyDoneFlags(from: defaults)
        let foldersDone = removeFolders(folders)
        let keychainDone = removeKeychainItems(using: keychain)
        let finished = foldersDone && keychainDone
        if finished { defaults.set(true, forKey: doneKey) }
        return finished
    }

    /// Where the Matrix-era folders would be on this device.
    static func liveFolders() -> [URL] {
        var folders: [URL] = []
        #if os(iOS)
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.chat.matron") {
            folders += containerFolders(in: container)
        }
        #elseif os(macOS)
        folders += containerFolders(in: StoragePaths.appSupport)
        #endif
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            folders.append(caches.appendingPathComponent(cachesFolderName, isDirectory: true))
        }
        return folders
    }

    static func containerFolders(in container: URL) -> [URL] {
        containerFolderNames.map { container.appendingPathComponent($0, isDirectory: true) }
    }

    static func removeVerifyDoneFlags(from defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(verifyDonePrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Removes each folder that exists. Always reports finished: a folder
    /// that cannot be removed now will not be removable next launch either.
    static func removeFolders(_ folders: [URL]) -> Bool {
        let fm = FileManager.default
        for folder in folders where fm.fileExists(atPath: folder.path) {
            do {
                try fm.removeItem(at: folder)
                logger.info("removed legacy folder \(folder.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("could not remove legacy folder \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }

    /// Deletes the recovery-key items. Finished unless the Keychain was
    /// locked (`errSecInteractionNotAllowed`), which a later launch can
    /// get past; a missing entitlement (unsigned builds) is final.
    static func removeKeychainItems(using keychain: KeychainEraser) -> Bool {
        let status = keychain.deleteService(recoveryKeychainService)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return true
        case errSecInteractionNotAllowed:
            logger.info("Keychain locked; legacy recovery key clean-up waits for a later launch")
            return false
        default:
            logger.error("could not delete legacy recovery key: OSStatus \(status, privacy: .public)")
            return true
        }
    }
}
