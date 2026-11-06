import Foundation

/// How much of the journal this device keeps (protocol "Sync scope").
///
/// `everything` mirrors every event of every conversation, which is what
/// every device did before this setting existed. `forYou` keeps the tracker,
/// missions, the Coordinator conversation and conversation titles and
/// states current, and fetches any other conversation when it is opened:
/// for a phone that mostly reads For you, most of the journal's traffic then
/// never reaches it.
public enum SyncScope: String, Sendable, CaseIterable, Identifiable {
    case everything
    case forYou = "for_you"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .everything: "Everything"
        case .forYou: "For you only"
        }
    }

    /// Per device, not per user: one phone can follow For you while the Mac
    /// keeps everything.
    public static let defaultsKey = "sync.scope"

    public static func stored(in defaults: UserDefaults = .standard) -> SyncScope {
        defaults.string(forKey: defaultsKey).flatMap(SyncScope.init(rawValue:)) ?? .everything
    }

    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
