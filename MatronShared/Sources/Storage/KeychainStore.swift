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
