import Foundation
import MatronModels

/// A memory's editor pushed onto the Missions tab's `[String]` stack
/// (spec 2026-09-27 memories): `id` is the memory's name. Names are
/// kebab-case (`^[a-z0-9][a-z0-9-]{0,63}$`), so they can never collide
/// with `MemoriesRoute.newMemory` or carry another route's prefix.
struct MemoryRoute: PathPrefixedRoute {
    let id: String
    static let pathPrefix = "memory/"

    init(id: String) { self.id = id }
}

/// One file from a box (the Memories screen's "On your boxes" section),
/// read-only: `id` is `"<box device id>/<absolute path>"`. The path keeps
/// its own leading slash, so the id splits at the first one.
struct LocalMemoryRoute: PathPrefixedRoute {
    let id: String
    static let pathPrefix = "boxmemory/"

    init(id: String) { self.id = id }

    init(ref: LocalMemoryRef) { self.init(id: "\(ref.boxID)\(ref.path.hasPrefix("/") ? "" : "/")\(ref.path)") }

    /// `nil` when the id is not a box id followed by a path.
    var ref: LocalMemoryRef? {
        guard let slash = id.firstIndex(of: "/"), let boxID = Int64(id[..<slash]) else { return nil }
        let path = String(id[slash...])
        return path.count > 1 ? LocalMemoryRef(boxID: boxID, path: path) : nil
    }
}

/// The Memories screens that aren't one memory: the list and the
/// new-memory form. Fixed stack entries, not `PathPrefixedRoute`s — they
/// carry no id.
enum MemoriesRoute {
    static let list = "memories/"
    static let newMemory = "memories/new"

    static func isMemoriesRoute(_ value: String) -> Bool {
        value == list || value == newMemory || MemoryRoute(pathValue: value) != nil
            || LocalMemoryRoute(pathValue: value) != nil
    }
}
