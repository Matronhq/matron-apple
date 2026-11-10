import Foundation
import MatronDesignSystem
import MatronModels

/// A project's page while the timeline is shown (`TimelineStoryHost`),
/// pushed in place of its `ProjectRoute` on whichever stack it is opened.
struct ProjectStoryRoute: PathPrefixedRoute {
    let id: String
    static let pathPrefix = "story/"
    init(id: String) { self.id = id }
}

/// One section of a project's page (the weeks it moved in, its missions,
/// its files), pushed one level down from the page. Rides a stack as
/// `"story-section/<section>/<project id>"`.
struct ProjectSectionRoute: Hashable {
    let projectID: String
    let section: ProjectSection
    static let pathPrefix = "story-section/"

    init(projectID: String, section: ProjectSection) {
        self.projectID = projectID
        self.section = section
    }

    var pathValue: String { Self.pathPrefix + section.rawValue + "/" + projectID }

    /// nil for anything but a known section of a named project.
    init?(pathValue: String) {
        guard pathValue.hasPrefix(Self.pathPrefix) else { return nil }
        let parts = pathValue.dropFirst(Self.pathPrefix.count).split(separator: "/", maxSplits: 1,
                                                                      omittingEmptySubsequences: false)
        guard parts.count == 2, let section = ProjectSection(rawValue: String(parts[0])), !parts[1].isEmpty
        else { return nil }
        self.init(projectID: String(parts[1]), section: section)
    }
}

/// The project a stack entry names, and the section of its page if any,
/// whichever of the three project routes carries it.
struct ProjectPageTarget: Equatable {
    let projectID: String
    /// nil is the page itself.
    let section: ProjectSection?

    init(projectID: String, section: ProjectSection?) {
        self.projectID = projectID
        self.section = section
    }

    /// nil when `pathValue` is not a project's page or a section of one.
    init?(pathValue: String) {
        if let route = ProjectSectionRoute(pathValue: pathValue) {
            self.init(projectID: route.projectID, section: route.section)
        } else if let route = ProjectStoryRoute(pathValue: pathValue) {
            self.init(projectID: route.id, section: nil)
        } else if let route = ProjectRoute(pathValue: pathValue) {
            self.init(projectID: route.id, section: nil)
        } else {
            return nil
        }
    }

    /// What an entry shows.
    enum Page: Equatable {
        /// The project's page while the timeline is shown, or a section of it.
        case summary(section: ProjectSection?)
        /// The project page without the timeline.
        case todaysPage
    }

    /// The route does not decide the page: an entry pushed before the
    /// journal answered shows the new page once the timeline is shown, and
    /// with the timeline hidden every entry is the project page of today.
    func page(timelineShown: Bool) -> Page {
        timelineShown ? .summary(section: section) : .todaysPage
    }
}

/// One of the timeline's lists ("All projects", "Went quiet", "Open a long
/// time", "Finished"), pushed onto the Projects stack from the iPhone's
/// week page.
struct TimelineListRoute: PathPrefixedRoute {
    let id: String
    static let pathPrefix = "timeline/"
    init(id: String) { self.id = id }

    /// nil for a week: the week page is the root, never pushed.
    init?(place: TimelinePlace) {
        switch place {
        case .projects: self.init(id: "projects")
        case .quiet: self.init(id: "quiet")
        case .long: self.init(id: "long")
        case .finished: self.init(id: "finished")
        case .week: return nil
        }
    }

    /// nil for an id that names no list.
    var place: TimelinePlace? {
        switch id {
        case "projects": return .projects
        case "quiet": return .quiet
        case "long": return .long
        case "finished": return .finished
        default: return nil
        }
    }
}
