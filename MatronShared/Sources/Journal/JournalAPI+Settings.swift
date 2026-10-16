import Foundation

/// The user's own journal settings (`GET` / `PATCH /settings`), synced per
/// user and sent live as the `settings` control frame.
public struct UserSettings: Equatable, Sendable {
    /// Whether agents file things the user should read as notices (items
    /// with a Seen button in For you) instead of leaving them in chat.
    public var notices: Bool
    /// After how many idle days the journal archives a conversation
    /// (protocol "Archived conversations"); 0 = never. `nil` from a journal
    /// without archiving, where Settings shows no choice.
    public var autoArchiveDays: Int?

    public init(notices: Bool = true, autoArchiveDays: Int? = nil) {
        self.notices = notices
        self.autoArchiveDays = autoArchiveDays
    }

    /// The journal's defaults, for anything its answer leaves out.
    public static let defaults = UserSettings()

    /// The auto-archive choices Settings offers, in days (0 = off).
    public static let autoArchiveChoices = [0, 14, 30, 90]

    /// "Off", "After 30 days"…, for any stored value, including one this
    /// build does not offer.
    public static func autoArchiveLabel(_ days: Int) -> String {
        days == 0 ? "Off" : "After \(days) day\(days == 1 ? "" : "s")"
    }

    /// Decodes a `GET`/`PATCH /settings` answer or the `settings` object of
    /// the control frame. A missing or malformed key reads as the default;
    /// a value that is not an object at all is `nil`.
    public static func decode(_ obj: Any?) -> UserSettings? {
        guard let obj = obj as? [String: Any] else { return nil }
        let days = (obj["auto_archive_days"] as? NSNumber).flatMap { number -> Int? in
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0,
                  number.doubleValue == number.doubleValue.rounded() else { return nil }
            return number.intValue
        }
        return UserSettings(notices: obj["notices"] as? Bool ?? defaults.notices, autoArchiveDays: days)
    }
}

/// `GET` / `PATCH /settings`. A protocol so `UserSettingsStore` tests fake it.
public protocol UserSettingsProviding: Sendable {
    func userSettings() async throws -> UserSettings
    /// Returns the settings as the journal stored them.
    func updateUserSettings(notices: Bool) async throws -> UserSettings
    /// `PATCH /settings {auto_archive_days}`. Returns the settings as the
    /// journal stored them.
    func updateUserSettings(autoArchiveDays: Int) async throws -> UserSettings
}

public extension UserSettingsProviding {
    /// Default for fakes predating the setting.
    func updateUserSettings(autoArchiveDays: Int) async throws -> UserSettings {
        throw JournalAPIError.notFound
    }
}

extension JournalAPI: UserSettingsProviding {
    public func userSettings() async throws -> UserSettings {
        try Self.decodeUserSettings(try await request(path: "/settings"))
    }

    public func updateUserSettings(notices: Bool) async throws -> UserSettings {
        try Self.decodeUserSettings(try await request(path: "/settings", method: "PATCH",
                                                      body: Self.userSettingsBody(notices: notices)))
    }

    public func updateUserSettings(autoArchiveDays: Int) async throws -> UserSettings {
        try Self.decodeUserSettings(try await request(path: "/settings", method: "PATCH",
                                                      body: ["auto_archive_days": autoArchiveDays]))
    }

    static func userSettingsBody(notices: Bool) -> [String: Any] {
        ["notices": notices]
    }

    static func decodeUserSettings(_ obj: [String: Any]) throws -> UserSettings {
        guard let settings = UserSettings.decode(obj) else { throw JournalAPIError.transport("malformed /settings response") }
        return settings
    }
}
