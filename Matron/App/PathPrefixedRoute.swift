import Foundation

/// A typed destination that rides a `[String]` navigation stack as
/// `"<prefix><id>"`. The chat stacks stay `[String]` (the sub-chat
/// switcher and `pushSpawnedRoom` rely on array semantics
/// `NavigationPath` doesn't offer), so anything that is not a
/// conversation has to encode itself into a string and decode back out.
/// One protocol means the two routes cannot drift on the prefix
/// round-trip or the empty-id guard.
///
/// Prefixes must be unique across conforming types: a decoder tries each
/// route in turn (`if let mission = MissionRoute(pathValue: v) … else if
/// let item = ItemRoute(pathValue: v)`), and a bare conversation id —
/// which never carries a prefix — falls through both.
protocol PathPrefixedRoute: Hashable {
    /// `"item/"`, `"mission/"`. Unique per conforming type.
    static var pathPrefix: String { get }
    var id: String { get }
    init(id: String)
}

extension PathPrefixedRoute {
    /// This route as a stack entry.
    var pathValue: String { Self.pathPrefix + id }

    /// Decodes a stack entry, or `nil` when it is not this route's: no
    /// prefix (a conversation id), another route's prefix, or an empty id.
    init?(pathValue: String) {
        guard pathValue.hasPrefix(Self.pathPrefix) else { return nil }
        let id = String(pathValue.dropFirst(Self.pathPrefix.count))
        guard !id.isEmpty else { return nil }
        self.init(id: id)
    }
}

/// True when `value` decodes as ANY known `PathPrefixedRoute` rather than
/// a bare conversation id. A "nearest chat below this route" computation
/// (`itemDestination`'s and `missionDestination`'s `current`, and their
/// `CoordinatorTabView` twins) must skip every route kind, not just the
/// one that existed when it was written — filtering on `ItemRoute` alone
/// let a `MissionRoute` entry pass as if it were the chat underneath it,
/// so dedupe pointed at the mission page itself instead of the chat
/// (Bugbot). One place means a future third route kind cannot repeat the
/// mistake at only some of the call sites.
func isAnyPathPrefixedRoute(_ value: String) -> Bool {
    ItemRoute(pathValue: value) != nil || MissionRoute(pathValue: value) != nil
}
