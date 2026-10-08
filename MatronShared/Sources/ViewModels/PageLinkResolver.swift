import Foundation
import MatronJournal
import MatronModels

/// Reads a mission or a project by its human-facing NUMBER — the store
/// calls a tapped `matron://mission/<n>` / `matron://project/<n>` link
/// needs. `JournalStore` conforms; tests fake it.
public protocol PageNumberReading: Sendable {
    func mission(num: Int) throws -> Mission?
    func project(num: Int) throws -> Project?
}
extension JournalStore: PageNumberReading {}

/// Resolves a tapped `matron://mission/<n>` or `matron://project/<n>` link
/// to the local page it names. The rule is `TrackerItemLinkResolver`'s:
/// look the number up locally; on a miss run exactly one list refresh and
/// look again (an agent may have started the mission seconds ago). A miss
/// after that is `.notSynced`, or `.failed` when the refresh itself failed
/// and so says nothing about whether the page exists.
///
/// The caller stays where it is on a miss and shows
/// `Resolution.alertMessage(for:)`.
public struct PageLinkResolver: Sendable {

    public enum Resolution {
        /// The page is on this device.
        case open(MatronPageTarget)
        /// A well-formed number that isn't in the local store, even after
        /// a refresh.
        case notSynced
        /// The store read threw, or the refresh failed.
        case failed(Error)
    }

    private let lookup: @Sendable (MatronPageLink) throws -> MatronPageTarget?
    /// One list refresh for the link's kind; the failure, if it failed.
    private let refresh: @Sendable (MatronPageLink) async -> MissionsRefreshFailure?

    /// Production wiring: the session's `JournalStore` and its sync actors.
    public init(store: any PageNumberReading, missions: MissionsSync, projects: ProjectsSync) {
        self.init(
            lookup: { link in
                switch link {
                case .mission(let num): return try store.mission(num: num).map { .mission(id: $0.id) }
                case .project(let num): return try store.project(num: num).map { .project(id: $0.id) }
                }
            },
            refresh: { link in
                switch link {
                case .mission:
                    if case .failed(let failure) = await missions.refresh() { return failure }
                case .project:
                    if case .failed(let failure) = await projects.refresh() { return failure }
                }
                return nil
            })
    }

    /// Seam init for tests.
    public init(lookup: @escaping @Sendable (MatronPageLink) throws -> MatronPageTarget?,
                refresh: @escaping @Sendable (MatronPageLink) async -> MissionsRefreshFailure?) {
        self.lookup = lookup
        self.refresh = refresh
    }

    public func resolve(_ link: MatronPageLink) async -> Resolution {
        do {
            if let target = try lookup(link) { return .open(target) }
        } catch {
            return .failed(error)
        }
        // One retry, never more: a link tap must not queue a run of fetches.
        let failure = await refresh(link)
        do {
            if let target = try lookup(link) { return .open(target) }
        } catch {
            return .failed(error)
        }
        // A failed refresh leaves the store as stale as it was, so "isn't
        // on this device yet" would be a guess: report the failure.
        if let failure { return .failed(failure) }
        return .notSynced
    }
}

extension PageLinkResolver.Resolution {
    /// What to put in the host's alert, or `nil` when the page opened.
    public func alertMessage(for link: MatronPageLink) -> String? {
        switch self {
        case .open:
            return nil
        case .notSynced:
            return "\(link.noun.capitalized) #\(link.num) isn't on this device yet."
        case .failed(let error):
            return "Couldn't open \(link.noun) #\(link.num) — \(error.localizedDescription)"
        }
    }
}
