import Foundation
import Security

public enum KeychainError: Error, LocalizedError {
    case unhandled(OSStatus)
    case dataCorrupted

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
    public init(service: String, accessGroup: String? = nil, synchronizable: Bool = false) {
        self.service = service
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
    }

    public func set(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataCorrupted
        }
        var query = baseQuery(for: key)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandled(updateStatus)
            }
        } else if status == errSecItemNotFound {
            query[kSecValueData as String] = data
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
        return query
    }
}
