import Foundation

/// A tracker item pushed onto a navigation stack (app shell, spec §3/§4).
/// The Decisions tab's stack is `[ItemRoute]`; the chat stacks stay
/// `[String]` (the sub-chat switcher and `pushSpawnedRoom` rely on array
/// semantics `NavigationPath` doesn't offer), so on those an item rides as
/// `pathValue` and the `String` destination decodes it with
/// `init?(pathValue:)`. Conversation ids never carry the prefix.
struct ItemRoute: Hashable {
    let id: String
    static let pathPrefix = "item/"

    init(id: String) { self.id = id }

    init?(pathValue: String) {
        guard pathValue.hasPrefix(Self.pathPrefix) else { return nil }
        let id = String(pathValue.dropFirst(Self.pathPrefix.count))
        guard !id.isEmpty else { return nil }
        self.id = id
    }

    var pathValue: String { Self.pathPrefix + id }
}
