import Foundation

/// Minimal interface for persisting the post-login `UserSession` blob.
/// `KeychainStore` already matches this shape. `FileSessionStore` is a
/// dev/simulator alternative that doesn't require keychain entitlements.
public protocol SessionStore: Sendable {
    func set(_ value: String, forKey key: String) throws
    func get(key: String) throws -> String?
    func delete(key: String) throws
}

extension KeychainStore: SessionStore {}

/// Plain file-based session store. Writes the value as UTF-8 to a file
/// `key`-named under `directory`. Used in Phase 1 because the iOS Simulator
/// rejects Keychain ops without a properly signed `keychain-access-groups`
/// entitlement (which needs a development team — out of scope until later).
public struct FileSessionStore: SessionStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func set(_ value: String, forKey key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try value.write(to: url(for: key), atomically: true, encoding: .utf8)
    }

    public func get(key: String) throws -> String? {
        let path = url(for: key)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try String(contentsOf: path, encoding: .utf8)
    }

    public func delete(key: String) throws {
        let path = url(for: key)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }
}
