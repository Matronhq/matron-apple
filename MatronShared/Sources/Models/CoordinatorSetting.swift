import Foundation

/// The designated coordinator conversation (app shell, spec §5b): one
/// convo id per signed-in journal user, stored in `UserDefaults` under
/// `coordinator.convoID.<userID>` — the same per-user key shape as
/// `UserDefaultsBoxCapacityCache`, and readable by `@AppStorage` through
/// `defaultsKey(for:)` so views update live. `nil` by default; clearing
/// removes the key. Nothing else about the conversation changes: it stays
/// in the Conversations list and opens from there as an ordinary chat.
public struct CoordinatorSetting {
    public static func defaultsKey(for userID: String) -> String {
        "coordinator.convoID.\(userID)"
    }

    private let defaults: UserDefaults
    private let key: String

    public init(userID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = Self.defaultsKey(for: userID)
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

    public static func clear(for userID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey(for: userID))
    }
}
