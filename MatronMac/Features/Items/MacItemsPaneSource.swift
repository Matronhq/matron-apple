import Foundation
import Observation
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// One row of the AppKit items pane list: an item in one of the pane's
/// sections, or a create the outbox has not sent yet.
///
/// An item can sit in two sections at once (an open task waiting on the
/// user is under Needs you and under Tasks), so a row's id is its
/// section's key and the item's id together.
struct MacItemsPaneRow: Identifiable, Equatable {
    enum Content: Equatable {
        /// `origin`: the origin chat's title, shown in the All scope only.
        case item(TrackerItem, origin: String?)
        case pending(ItemsListView.PendingRow)
    }

    var id: String
    var section: MacItemsPaneSection
    var content: Content

    init(item: TrackerItem, section: MacItemsPaneSection, origin: String?) {
        id = section.rowID(item.id)
        self.section = section
        content = .item(item, origin: origin)
    }

    init(pending: ItemsListView.PendingRow) {
        id = MacItemsPaneSection.pending.rowID(pending.id)
        section = .pending
        content = .pending(pending)
    }

    var item: TrackerItem? {
        if case .item(let item, _) = content { return item }
        return nil
    }
}

/// The pane's sections, in `ItemsListView`'s order. Every publication
/// carries all five (an empty one shows no header), so a section's index
/// never moves.
enum MacItemsPaneSection: String, CaseIterable, Sendable {
    case pending, needsYou, tasks, decisions, done

    var title: String {
        switch self {
        case .pending: "Pending"
        case .needsYou: "Needs you"
        case .tasks: "Tasks"
        case .decisions: "Decisions"
        case .done: "Done"
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self)! }

    func rowID(_ id: String) -> String { "\(rawValue):\(id)" }

    /// The section and item id a row id names.
    static func parse(_ rowID: String) -> (section: MacItemsPaneSection, id: String)? {
        guard let colon = rowID.firstIndex(of: ":"),
              let section = MacItemsPaneSection(rawValue: String(rowID[..<colon])) else { return nil }
        return (section, String(rowID[rowID.index(after: colon)...]))
    }
}

/// The AppKit items pane list's data, on the main actor: the pane's
/// sections read from `ItemsPanelViewModel` (which the items index feeds)
/// and the pane's origin titles, handed to `MacListView` as
/// `ListPublication`s that name only the rows that changed. The same
/// shape as `MacDecisionsSource`; a scope change is a reload.
@Observable @MainActor
final class MacItemsPaneSource {
    typealias Publication = ListPublication<MacItemsPaneRow, String>

    /// `nil` until the first publication; then whether the pane has no
    /// rows, for its empty state. Written only when it flips.
    private(set) var isEmpty: Bool?
    /// The Tasks section's item ids as last published, for a drop's
    /// source index.
    @ObservationIgnored private(set) var taskIDs: [String] = []

    @ObservationIgnored private let viewModel: ItemsPanelViewModel
    @ObservationIgnored private let originTitles: () -> [String: String]
    @ObservationIgnored private var continuation: AsyncStream<Publication>.Continuation?
    @ObservationIgnored private var shownKey: String?
    @ObservationIgnored private var shownSections: [ListSection<String>] = []
    @ObservationIgnored private var shownRows: [String: MacItemsPaneRow] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var publishedCountForTesting = 0

    /// `originTitles` is read inside observation tracking: an observable
    /// source (the pane's state) republishes when it changes.
    init(viewModel: ItemsPanelViewModel, originTitles: @escaping () -> [String: String]) {
        self.viewModel = viewModel
        self.originTitles = originTitles
    }

    func publications() -> AsyncStream<Publication> {
        stop()
        generation += 1
        let generation = generation
        let (stream, continuation) = AsyncStream<Publication>.makeStream()
        self.continuation = continuation
        shownKey = nil
        shownSections = []
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

    /// A row as last published, by its id.
    func row(_ id: String) -> MacItemsPaneRow? { shownRows[id] }

    func stop() {
        continuation?.finish()
        continuation = nil
    }

    static func scopeKey(_ scope: ItemsScope) -> String {
        switch scope {
        case .all: "all"
        case .convo(let id): "convo:\(id)"
        }
    }

    /// The pane's rows as the models say now, one section per
    /// `MacItemsPaneSection`. Origins show in the All scope only, falling
    /// back to "Another chat", as `ItemsListView` has them.
    static func rows(viewModel: ItemsPanelViewModel, originTitles: [String: String])
        -> (key: String, sections: [ListSection<String>], rows: [MacItemsPaneRow]) {
        let isAll = viewModel.scope == .all
        func origin(_ item: TrackerItem) -> String? {
            isAll ? (originTitles[item.originConvoID] ?? "Another chat") : nil
        }
        let sections = viewModel.sections
        let pending = viewModel.pendingCreates.map {
            ItemsListView.PendingRow(id: $0.id, kind: $0.kind, title: $0.title, isFailed: $0.lastError != nil,
                                     error: $0.lastError)
        }
        var groups: [[MacItemsPaneRow]] = [pending.map { MacItemsPaneRow(pending: $0) }]
        for (section, items) in [(MacItemsPaneSection.needsYou, sections.needsYou), (.tasks, sections.tasks),
                                 (.decisions, sections.decisions), (.done, sections.done)] {
            groups.append(items.map { MacItemsPaneRow(item: $0, section: section, origin: origin($0)) })
        }
        let listSections = zip(MacItemsPaneSection.allCases, groups).map { section, rows in
            ListSection(key: section.rawValue, ids: rows.map(\.id))
        }
        return (scopeKey(viewModel.scope), listSections, groups.flatMap { $0 })
    }

    /// The update from what was shown to `sections`: a reset on a scope
    /// change (or the first publication), else the rows that were added,
    /// removed or changed.
    static func publication(fromKey oldKey: String?, sections oldSections: [ListSection<String>],
                            rows oldRows: [String: MacItemsPaneRow], toKey key: String,
                            sections: [ListSection<String>], rows: [MacItemsPaneRow]) -> Publication {
        guard oldKey == key else { return Publication(update: .reset(sections), rows: rows) }
        var touched: Set<String> = []
        var newIDs: Set<String> = []
        for row in rows {
            newIDs.insert(row.id)
            if oldRows[row.id] != row { touched.insert(row.id) }
        }
        for section in oldSections {
            for id in section.ids where !newIDs.contains(id) { touched.insert(id) }
        }
        let update = ListUpdate(from: oldSections, to: sections, touched: touched)
        return Publication(update: update, rows: rows)
    }

    private func track() {
        guard let continuation else { return }
        // A chain registered for an earlier stream ends here rather than
        // running beside the current one.
        let generation = generation
        let next = withObservationTracking {
            Self.rows(viewModel: viewModel, originTitles: originTitles())
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.track()
            }
        }
        let publication = Self.publication(fromKey: shownKey, sections: shownSections, rows: shownRows,
                                           toKey: next.key, sections: next.sections, rows: next.rows)
        guard shownKey != next.key || publication.update.hasChanges else { return }
        shownKey = next.key
        shownSections = next.sections
        shownRows = Dictionary(next.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        taskIDs = next.rows.compactMap { $0.section == .tasks ? $0.item?.id : nil }
        publishedCountForTesting += 1
        if isEmpty != next.rows.isEmpty { isEmpty = next.rows.isEmpty }
        continuation.yield(publication)
    }
}
