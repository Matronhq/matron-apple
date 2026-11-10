import Foundation

/// What a timeline place shows right now: its page when loaded, else
/// progress, the retry, or (no weeks at all) the empty state. Built by
/// `TimelineViewModel.content(for:)`, drawn by `TimelinePlaceView`.
public enum TimelinePlaceContent: Equatable, Sendable {
    /// The chosen week, with its sidebar sentence (the lede when the week has none).
    case week(TimelineWeek, sentence: String?)
    case quiet(StalledList)
    case long(StalledList)
    case finished([FinishedProject], hasMore: Bool)
    /// Every project, as far as it has been paged.
    case projects(TimelineProjectList, hasMore: Bool)
    /// The journal lists no weeks yet.
    case nothingYet
    case loading
    /// The read failed with nothing to show.
    case failed
}
