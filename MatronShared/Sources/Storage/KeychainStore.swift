import Foundation
import Security

public enum KeychainError: Error, LocalizedError {
    case unhandled(OSStatus)
    case dataCorrupted

    /// The `OSStatus` behind an `.unhandled` error, `nil` otherwise.
    public var status: OSStatus? {
        if case .unhandled(let status) = self { return status }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(message)"
        case .dataCorrupted:
            return "Keychain value could not be decoded as UTF-8."
        }
    }
}

public struct KeychainStore: SessionStore {
    private let service: String
    private let accessGroup: String?
    private let synchronizable: Bool
    /// A `kSecAttrAccessible…` value, held as `String` so the store stays
    /// `Sendable` (CF types are not).
    private let accessibility: String?
    private let useDataProtectionKeychain: Bool

    /// - Parameters:
    ///   - service: Keychain service name (typically the bundle ID).
    ///   - accessGroup: Optional keychain access group for sharing items
    ///     across same-team apps and extensions.
    ///   - synchronizable: When `true`, items are tagged with
    ///     `kSecAttrSynchronizable=true` so iCloud Keychain replicates them
    ///     across the user's signed-in devices. Used by `RecoveryKeyManager`
    ///     so a fresh install on another device can read the recovery key
    ///     without re-entry. Synchronizable items live in a separate
    ///     keychain namespace from non-synchronizable ones — the same
    ///     `service` + key stored with both flags refers to two distinct
    ///     entries.
    ///   - accessibility: Optional `kSecAttrAccessible…` class for the items
    ///     this store writes (set on add and update, never used to match,
    ///     so an item written earlier with another class is still found).
    ///     `nil` leaves the system default.
    ///   - useDataProtectionKeychain: macOS only. Adds
    ///     `kSecUseDataProtectionKeychain` to every query, so items live in
    ///     the iOS-style keychain (access groups, accessibility classes, no
    ///     per-app access prompts) instead of the legacy login keychain.
    ///     Needs the `keychain-access-groups` entitlement; without it every
    ///     call fails with `errSecMissingEntitlement`. Ignored on iOS, where
    ///     that is the only keychain.
    public init(service: String, accessGroup: String? = nil, synchronizable: Bool = false,
                accessibility: CFString? = nil, useDataProtectionKeychain: Bool = false) {
        self.service = service
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
        self.accessibility = accessibility.map { $0 as String }
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    public func set(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataCorrupted
        }
        var query = baseQuery(for: key)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            var attributes: [String: Any] = [kSecValueData as String: data]
            if let accessibility {
                attributes[kSecAttrAccessible as String] = accessibility
            }
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandled(updateStatus)
            }
        } else if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            if let accessibility {
                query[kSecAttrAccessible as String] = accessibility
            }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(addStatus)
            }
        } else {
            throw KeychainError.unhandled(status)
        }
    }

    public func get(key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataCorrupted
        }
        return string
    }

    public func delete(key: String) throws {
        let query = baseQuery(for: key)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    /// Recovery-key store factory. Funnels every recovery-key Keychain
    /// construction through one place so the service name +
    /// synchronizable flag stay in lockstep.
    ///
    /// **Wave 5 bugbot #3 revert.** Earlier waves passed an explicit
    /// `accessGroup: KeychainAccessGroups.recovery` (which itself was a
    /// `$(AppIdentifierPrefix)…` literal). That token only expands inside
    /// signed entitlement plists, NOT in Swift string literals — so every
    /// signed build returned `errSecMissingEntitlement` from
    /// `SecItemAdd` / `SecItemCopyMatching` and the entire recovery-key
    /// feature was non-functional outside the SPM test host. See
    /// `KeychainAccessGroups.swift` for the full rationale.
    ///
    /// Today both apps declare exactly one entry in
    /// `keychain-access-groups`, so omitting `kSecAttrAccessGroup` lets the
    /// system fall back to "the first entry in `keychain-access-groups`" —
    /// which is ours. That's the pre-Wave-3 shipping shape, and it works.
    ///
    /// **TODO Phase 4:** when iOS NSE adds a second access group, EITHER
    /// keep the recovery group first in the entitlement (cheapest), OR
    /// resolve the live access-group string at runtime via
    /// `SecItemCopyMatching` with `kSecReturnAttributes: true` and cache
    /// it (correct long-term — but requires making this factory async /
    /// throws so it can wait on the first probe). Do NOT re-introduce a
    /// `$(AppIdentifierPrefix)…` literal — `KeychainAccessGroups.swift`'s
    /// docblock and the `RecoveryKeyManagerTests`/`KeychainProbeTests`
    /// regression-guard tests are the trip-wire for this.
    ///
    /// `synchronizable: true` because recovery keys ride iCloud Keychain
    /// to enable additional-device install without re-entering the key.
    /// The team-prefixed `keychain-access-groups` entitlement we already
    /// declare is sufficient for iCloud Keychain ride — no extra
    /// `com.apple.developer.icloud-services` capability is required.
    /// User must have iCloud Keychain enabled in System Settings for
    /// the cross-device sync to actually take effect. Session 6
    /// (2026-04-30) confirmed end-to-end persistence + sync on an
    /// org-team-signed Mac Debug build with this exact shape.
    public static func recoveryStore() -> KeychainStore {
        return KeychainStore(
            service: "chat.matron.recovery",
            synchronizable: true
        )
    }

    /// Store for the signed-in session (`JournalAuthService`'s blob: access
    /// token, user and device ids). Use it through `SessionStores.live`,
    /// which falls back to a file when the Keychain is unusable.
    ///
    /// - Not synchronizable, and `…AfterFirstUnlockThisDeviceOnly`: the
    ///   session is a per-device credential, so it never rides iCloud
    ///   Keychain or a device backup restored elsewhere, and it is readable
    ///   once the device has been unlocked after boot (the app can still
    ///   restore it on a background launch).
    /// - No explicit access group, for the reason given on
    ///   `recoveryStore()`: the item lands in the first
    ///   `keychain-access-groups` entry, `$(AppIdentifierPrefix)chat.matron`.
    ///   The iOS share extension declares the same single entry, so it
    ///   reads the same item.
    /// - macOS uses the data-protection keychain. In the legacy login
    ///   keychain the accessibility class above is ignored and the item's
    ///   access list is tied to the app's code signature, so a rebuilt or
    ///   re-signed app gets a "wants to use your confidential information"
    ///   prompt. The data-protection keychain has neither problem and is
    ///   where the recovery key already lives (synchronizable items always
    ///   are). It needs the `keychain-access-groups` entitlement, which the
    ///   Release and team-signed Debug builds have; the ad-hoc signed
    ///   build does not, gets `errSecMissingEntitlement`, and keeps the
    ///   session in the file instead.
    public static func sessionStore() -> KeychainStore {
        #if os(macOS)
        let dataProtection = true
        #else
        let dataProtection = false
        #endif
        return KeychainStore(
            service: "chat.matron.session",
            synchronizable: false,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            useDataProtectionKeychain: dataProtection
        )
    }

    private func baseQuery(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if synchronizable {
            // kCFBooleanTrue!: documented non-null on all platforms we ship.
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue!
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue!
        }
        #endif
        return query
    }
}
