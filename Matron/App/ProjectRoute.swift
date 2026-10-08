import SwiftUI

/// A project page pushed onto the Projects tab's `[String]` stack.
struct ProjectRoute: PathPrefixedRoute {
    let id: String
    static let pathPrefix = "project/"
    init(id: String) { self.id = id }
}

extension EnvironmentValues {
    /// Opens a project page from wherever a mission page is mounted. The
    /// Projects tab pushes; every other tab hands off to the Projects tab
    /// (`AppShellView` installs both).
    @Entry var openProject: ((String) -> Void)? = nil
}
