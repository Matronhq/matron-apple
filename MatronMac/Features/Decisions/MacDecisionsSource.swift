import Foundation
import Observation
import MatronJournal
import MatronModels
import MatronViewModels

/// One row of the AppKit For you list: an item with its origin label, or
/// the Done tab's "Show more" under its window.
struct MacDecisionsRow: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        /// `isClosedTab`: drawn with the Done tab's "Answered · 2h ago"
        /// caption, and no Seen button.
        case item(TrackerItem, origin: String, isClosedTab: Bool)
        case showMore
    }

    static let showMoreID = "decisions.showMore"

    var id: String
    var content: Content

    init(item: TrackerItem, origin: String, isClosedTab: Bool) {
        id = item.id
        content = .item(item, origin: origin, isClosedTab: isClosedTab)
    }

    private init(id: String, content: Content) {
        self.id = id
        self.content = content
    }

    static let showMore = MacDecisionsRow(id: showMoreID, content: .showMore)

    var item: TrackerItem? {
        if case .item(let item, _, _) = content { return item }
        return nil
    }
}

/// The AppKit For you list's data, on the main actor: the rows of the tab
/// on show, read from `ItemsPanelViewModel` (which the items index feeds)
/// and the window's origin labels, handed to `MacListView` as
/// `ListPublication`s that name only the rows that changed.
///
/// The view model's lists are watched through observation tracking: a
/// change re-reads them once, on the next main-actor turn, however many
/// properties it touched. The rows are tens to a few hundred, so the
/// comparison is cheap; what it saves is the per-row SwiftUI work.
///
/// Cheap to make: nothing starts until `publications()` is called, which
/// `MacListView` does once, when its host is made.
@Observable @MainActor
final class MacDecisionsSource {
    typealias Publication = ListPublication<MacDecisionsRow, String>

    /// `nil` until the first publication; then whether the tab on show has
    /// no rows, for the list's empty state. Written only when it flips, so
    /// the view around the list does not re-render per change.
    private(set) var isEmpty: Bool?

    @ObservationIgnored private let viewModel: ItemsPanelViewModel
    @ObservationIgnored private let originLabels: MacOriginLabels
    @ObservationIgnored private var continuation: AsyncStream<Publication>.Continuation?
    /// What the last publication showed.
    @ObservationIgnored private var shownKey: String?
    @ObservationIgnored private var shownIDs: [String] = []
    @ObservationIgnored private var shownRows: [String: MacDecisionsRow] = [:]
    /// Bumped per `publications()`, so an older stream ending stops nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var publishedCountForTesting = 0

    init(viewModel: ItemsPanelViewModel, originLabels: MacOriginLabels) {
        self.viewModel = viewModel
        self.originLabels = originLabels
    }

    /// The list's publications, for `MacListView`. A second call replaces
    /// the first stream.
    func publications() -> AsyncStream<Publication> {
        stop()
        generation += 1
        let generation = generation
        let (stream, continuation) = AsyncStream<Publication>.makeStream()
        self.continuation = continuation
        shownKey = nil
        shownIDs = []
        shownRows = [:]
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.stop()
            }
        }
        track()
        return stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }

    /// The tab on show and its rows, as the models say now.
    static func rows(viewModel: ItemsPanelViewModel, labels: ItemOriginLabels) -> (key: String, rows: [MacDecisionsRow]) {
        func origin(_ item: TrackerItem) -> String { labels.label(for: item) ?? "Another chat" }
        switch viewModel.forYouTab {
        case .open:
            return (ForYouTab.open.rawValue,
                    viewModel.awaitingYou.map { MacDecisionsRow(item: $0, origin: origin($0), isClosedTab: false) })
        case .closed:
            var rows = viewModel.decided.prefix(viewModel.decidedVisibleCount)
                .map { MacDecisionsRow(item: $0, origin: origin($0), isClosedTab: true) }
            if viewModel.hasMoreDecided { rows.append(.showMore) }
            return (ForYouTab.closed.rawValue, rows)
        case .spare:
            return (ForYouTab.spare.rawValue,
                    viewModel.spareAllowance.map { MacDecisionsRow(item: $0, origin: origin($0), isClosedTab: false) })
        }
    }

    /// The update from what was shown (`oldKey`, `oldIDs`, `oldRows`) to
    /// `rows`: a reset on a tab change (or the first publication), else
    /// the rows that were added, removed or changed.
    static func publication(fromKey oldKey: String?, ids oldIDs: [String], rows oldRows: [String: MacDecisionsRow],
                            toKey key: String, rows: [MacDecisionsRow]) -> Publication {
        let sections = [ListSection(key: key, ids: rows.map(\.id))]
        guard oldKey == key else { return Publication(update: .reset(sections), rows: rows) }
        var touched: Set<String> = []
        var newIDs: Set<String> = []
        for row in rows {
            newIDs.insert(row.id)
            if oldRows[row.id] != row { touched.insert(row.id) }
        }
        for id in oldIDs where !newIDs.contains(id) { touched.insert(id) }
        let update = ListUpdate(from: [ListSection(key: key, ids: oldIDs)], to: sections, touched: touched)
        return Publication(update: update, rows: rows)
    }

    /// Publishes the rows, and again whenever something they read changes.
    private func track() {
        guard let continuation else { return }
        // A chain registered for an earlier stream ends here rather than
        // running beside the current one.
        let generation = generation
        let next = withObservationTracking {
            Self.rows(viewModel: viewModel, labels: originLabels.labels)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.track()
            }
        }
        let publication = Self.publication(fromKey: shownKey, ids: shownIDs, rows: shownRows,
                                           toKey: next.key, rows: next.rows)
        guard shownKey != next.key || publication.update.hasChanges else { return }
        shownKey = next.key
        shownIDs = next.rows.map(\.id)
        shownRows = Dictionary(next.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        publishedCountForTesting += 1
        if isEmpty != next.rows.isEmpty { isEmpty = next.rows.isEmpty }
        continuation.yield(publication)
    }
}
