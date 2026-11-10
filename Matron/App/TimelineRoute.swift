import Foundation
import MatronModels

/// A project told as its story (`ProjectStoryView`), pushed onto the
/// Projects stack from the timeline. Its "All details" pushes the
/// project's `ProjectRoute` on top.
struct ProjectStoryRoute: PathPrefixedRoute {
    let id: String
    static let pathPrefix = "story/"
    init(id: String) { self.id = id }
}

/// One of the timeline's three lists ("Went quiet", "Open a long time",
/// "Finished"), pushed onto the Projects stack from the iPhone's week page.
struct TimelineListRoute: PathPrefixedRoute {
    let id: String
    static let pathPrefix = "timeline/"
    init(id: String) { self.id = id }

    /// nil for a week (the week page is the root, never pushed) and for
    /// the all-projects list, which has no route here.
    init?(place: TimelinePlace) {
        switch place {
        case .quiet: self.init(id: "quiet")
        case .long: self.init(id: "long")
        case .finished: self.init(id: "finished")
        case .week, .projects: return nil
        }
    }

    /// nil for an id that names no list.
    var place: TimelinePlace? {
        switch id {
        case "quiet": return .quiet
        case "long": return .long
        case "finished": return .finished
        default: return nil
        }
    }
}
