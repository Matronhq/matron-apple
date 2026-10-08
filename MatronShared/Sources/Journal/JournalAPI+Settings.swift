import Foundation

/// The user's own journal settings (`GET` / `PATCH /settings`), synced per
/// user and sent live as the `settings` control frame. Only `notices` so
/// far: whether agents file things the user should read as notices (items
/// with a Seen button in For you) instead of leaving them in chat.
public struct UserSettings: Equatable, Sendable {
    public var notices: Bool

    public init(notices: Bool = true) {
        self.notices = notices
    }

    /// The journal's defaults, for anything its answer leaves out.
    public static let defaults = UserSettings()

    /// Decodes a `GET`/`PATCH /settings` answer or the `settings` object of
    /// the control frame. A missing or malformed key reads as the default;
    /// a value that is not an object at all is `nil`.
    public static func decode(_ obj: Any?) -> UserSettings? {
        guard let obj = obj as? [String: Any] else { return nil }
        return UserSettings(notices: obj["notices"] as? Bool ?? defaults.notices)
    }
}

/// `GET` / `PATCH /settings`. A protocol so `UserSettingsStore` tests fake it.
public protocol UserSettingsProviding: Sendable {
    func userSettings() async throws -> UserSettings
    /// Returns the settings as the journal stored them.
    func updateUserSettings(notices: Bool) async throws -> UserSettings
}

extension JournalAPI: UserSettingsProviding {
    public func userSettings() async throws -> UserSettings {
        try Self.decodeUserSettings(try await request(path: "/settings"))
    }

    public func updateUserSettings(notices: Bool) async throws -> UserSettings {
        try Self.decodeUserSettings(try await request(path: "/settings", method: "PATCH",
                                                      body: Self.userSettingsBody(notices: notices)))
    }

    static func userSettingsBody(notices: Bool) -> [String: Any] {
        ["notices": notices]
    }

    static func decodeUserSettings(_ obj: [String: Any]) throws -> UserSettings {
        guard let settings = UserSettings.decode(obj) else { throw JournalAPIError.transport("malformed /settings response") }
        return settings
    }
}
