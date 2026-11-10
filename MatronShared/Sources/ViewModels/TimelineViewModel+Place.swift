import Foundation
import MatronModels

/// What one place of the timeline shows, for the hosts on every platform.
extension TimelineViewModel {
    /// The loaded week when it is the one chosen: a pick of another week
    /// shows progress (or the retry) until that week arrives, never the
    /// last week's cards under the new title.
    public static func shownWeek(_ week: TimelineWeek?, for place: TimelinePlace?) -> TimelineWeek? {
        guard case .week(let key) = place, let week, week.week == key else { return nil }
        return week
    }

    public func content(for place: TimelinePlace?) -> TimelinePlaceContent {
        let unloaded: TimelinePlaceContent = error != nil ? .failed : .loading
        switch place {
        case .week:
            guard let week = Self.shownWeek(week, for: place) else { return unloaded }
            return .week(week)
        case .quiet:
            return quiet.map { .quiet($0) } ?? unloaded
        case .long:
            return long.map { .long($0) } ?? unloaded
        case .finished:
            return hasLoadedFinished ? .finished(finished, hasMore: hasMoreFinished) : unloaded
        case .projects:
            return allProjects.map { .projects($0, hasMore: hasMoreProjects) } ?? unloaded
        case nil:
            return weeks.isEmpty && error == nil ? .nothingYet : unloaded
        }
    }

    /// Whether the hosts offer "All projects": until the journal says it
    /// has no such list.
    public var showsAllProjects: Bool { projectsSupported != false }

    /// Whether `place` has a page on screen (a finished or all-projects list once read, even empty).
    public func hasContent(for place: TimelinePlace?) -> Bool {
        switch place {
        case .week: return Self.shownWeek(week, for: place) != nil
        case .quiet: return quiet != nil
        case .long: return long != nil
        case .finished: return hasLoadedFinished
        case .projects: return allProjects != nil
        case nil: return false
        }
    }

    /// The week's pictures to load (videos draw their own panel).
    public func imageBlobIDs(for place: TimelinePlace?) -> [String] {
        Self.shownWeek(week, for: place)?.stories.compactMap(\.media).filter { !$0.isVideo }.map(\.blobID) ?? []
    }

    /// Whether `place`'s page says the last error over what it shows: a
    /// failed read over a page already on screen, or a failed Ask. Only
    /// the place being read says so: a page kept mounted under another
    /// (the iPhone's week under a pushed list) stays quiet.
    public func showsError(on place: TimelinePlace?) -> Bool {
        error != nil && self.place == place && hasContent(for: place)
    }
}
