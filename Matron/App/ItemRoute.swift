import Foundation

/// A tracker item pushed onto a navigation stack (app shell, spec §3/§4).
/// The Decisions tab's stack is `[ItemRoute]`; the chat stacks stay
/// `[String]`, so on those an item rides as `pathValue` and the `String`
/// destination decodes it with `init?(pathValue:)` — both defaulted by
/// `PathPrefixedRoute`. Conversation ids never carry the prefix.
struct ItemRoute: PathPrefixedRoute {
    let id: String
    static let pathPrefix = "item/"

    init(id: String) { self.id = id }
}
