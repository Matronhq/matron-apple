import Foundation

/// Where the app keeps what it remembers per item and per room.
///
/// These keys grow with use (one per tracker item opened, one or two per
/// room) and nothing removes them. In `UserDefaults.standard` they made
/// every defaults write expensive: `@AppStorage` registers KVO observers
/// on the standard domain, so each write diffs the whole domain on the
/// main thread, and launch samples on a long-used Mac showed that diff at
/// 0.3–0.45 s a time. A suite of their own is a separate domain nobody
/// observes.
public enum MatronDefaults {
    public static let memorySuiteName = "chat.matron.memory"

    /// The prefixes of the keys that live in `memory`.
    public static let memoryKeyPrefixes = ["items.readToEnd.", "matron.answeredPrompts.", "matron.agentChatAnswers."]

    /// Set in `memory` once the standard domain's keys have moved.
    static let movedKey = "memory.movedFromStandard"

    /// The per-item and per-room memory. The first use moves any such keys
    /// left in the standard domain by earlier versions.
    public static let memory: UserDefaults = {
        guard let memory = UserDefaults(suiteName: memorySuiteName) else { return .standard }
        if !memory.bool(forKey: movedKey), let domain = Bundle.main.bundleIdentifier {
            moveMemoryKeys(from: .standard, domain: domain, to: memory)
        }
        return memory
    }()

    /// Copies every key with a `memoryKeyPrefixes` prefix from `source`'s
    /// persistent `domain` into `destination`, without overwriting a value
    /// already there, then removes them from `domain` in one write. Marks
    /// `destination` as moved. Returns how many moved.
    @discardableResult
    public static func moveMemoryKeys(from source: UserDefaults, domain: String, to destination: UserDefaults) -> Int {
        defer { destination.set(true, forKey: movedKey) }
        guard let values = source.persistentDomain(forName: domain) else { return 0 }
        let keys = values.keys.filter { key in memoryKeyPrefixes.contains { key.hasPrefix($0) } }
        guard !keys.isEmpty else { return 0 }
        for key in keys where destination.object(forKey: key) == nil {
            destination.set(values[key], forKey: key)
        }
        removeKeys(keys, fromDomain: domain)
        return keys.count
    }

    /// Removes `keys` from the current user's `domain` in one write.
    ///
    /// One `removeObject(forKey:)` per key would post a change per key, and
    /// with the domain observed each one costs a diff of the whole domain.
    /// Replacing the domain with `setPersistentDomain` costs one, but loses
    /// any write another thread makes between the read and the replace.
    /// `CFPreferencesSetMultiple` removes just these keys, in one change.
    public static func removeKeys(_ keys: [String], fromDomain domain: String) {
        guard !keys.isEmpty else { return }
        CFPreferencesSetMultiple(nil, keys as CFArray, domain as CFString,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
