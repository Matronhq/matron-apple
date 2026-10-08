import Foundation

/// A mission page pushed onto a `[String]` navigation stack — the Missions
/// tab's own stack, or whichever chat stack a milestone card was tapped on.
struct MissionRoute: PathPrefixedRoute {
    let id: String
    static let pathPrefix = "mission/"

    init(id: String) { self.id = id }
}
