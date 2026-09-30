import Foundation

/// A memory's editor pushed onto the Missions tab's `[String]` stack
/// (spec 2026-09-27 memories): `id` is the memory's name. Names are
/// kebab-case (`^[a-z0-9][a-z0-9-]{0,63}$`), so they can never collide
/// with `MemoriesRoute.newMemory` or carry another route's prefix.
struct MemoryRoute: PathPrefixedRoute {
    let id: String
    static let pathPrefix = "memory/"

    init(id: String) { self.id = id }
}

/// The Memories screens that aren't one memory: the list and the
/// new-memory form. Fixed stack entries, not `PathPrefixedRoute`s — they
/// carry no id.
enum MemoriesRoute {
    static let list = "memories/"
    static let newMemory = "memories/new"

    static func isMemoriesRoute(_ value: String) -> Bool {
        value == list || value == newMemory || MemoryRoute(pathValue: value) != nil
    }
}
