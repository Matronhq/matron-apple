import Foundation

/// This device's copy of the user's Coordinator conversation. Since the
/// Coordinator redesign (spec §3a) the journal holds the setting and
/// `CoordinatorSync` mirrors it here; views keep reading this key
/// (`@AppStorage` through `defaultsKey(for:)`, or
/// `UserDefaults.didChangeNotification`) so they stay live. Views never
/// write it directly — user picks go through `CoordinatorSync.set(_:)`.
public struct CoordinatorSetting {
    /// "New coordinator chat…" starts the session on this model (spec §2e).
    public static let newChatModel = "opus[1m]"

    public static func defaultsKey(for userID: String) -> String {
        "coordinator.convoID.\(userID)"
    }

    /// Set once this device has reconciled with a journal that knows the
    /// setting, so the first-launch "push my cached id" rule runs once.
    public static func migratedKey(for userID: String) -> String {
        "coordinator.migrated.\(userID)"
    }

    /// What a reconcile does with the journal's answer.
    public enum Reconcile: Equatable, Sendable {
        /// Take this value into the cache (nil clears it).
        case adopt(String?)
        /// `PUT` this cached id: the journal has none and this device is the
        /// first to upgrade.
        case push(String)
    }

    /// The spec §3a rule. The journal's value always wins; a cached id is
    /// pushed only before this device's first successful reconcile.
    public static func reconcile(journal: String?, cached: String?, migrated: Bool) -> Reconcile {
        if let journal { return .adopt(journal) }
        if !migrated, let cached, !cached.isEmpty { return .push(cached) }
        return .adopt(nil)
    }

    private let defaults: UserDefaults
    private let key: String
    private let migratedDefaultsKey: String

    public init(userID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = Self.defaultsKey(for: userID)
        self.migratedDefaultsKey = Self.migratedKey(for: userID)
    }

    public var convoID: String? {
        get { defaults.string(forKey: key) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    public var migrated: Bool {
        get { defaults.bool(forKey: migratedDefaultsKey) }
        nonmutating set { defaults.set(newValue, forKey: migratedDefaultsKey) }
    }

    public static func clear(for userID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey(for: userID))
        defaults.removeObject(forKey: migratedKey(for: userID))
    }
}

/// `UserDefaults` is thread-safe; the struct holds nothing else.
extension CoordinatorSetting: @unchecked Sendable {}
