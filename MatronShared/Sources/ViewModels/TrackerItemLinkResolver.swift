import Foundation
import MatronJournal
import MatronModels

/// Reads one tracker item by its human-facing NUMBER (`#65`) — the single
/// store call a tapped `[#65](matron://item/65)` link needs. `JournalStore`
/// conforms; tests fake it. Deliberately NOT folded into
/// `ItemsStoreReading`: the resolver wants nothing else from the store, and
/// every panel/detail fake would otherwise have to grow a method it never
/// uses.
public protocol TrackerItemNumberReading: Sendable {
    func item(num: Int) throws -> TrackerItem?
}
extension JournalStore: TrackerItemNumberReading {}

/// Resolves a tapped `matron://item/<n>` link to a local item id (item #115).
///
/// Every install site — iOS chat, iOS item detail, the Mac items pane, the
/// Mac Decisions detail — routes through this one type so the miss path
/// cannot drift between them. The rule:
///
/// 1. Look the number up locally.
/// 2. On a miss, run **exactly one** `refresh(scope: .all)` through the
///    existing items-sync path and look again — the number is very often a
///    real item this device simply hasn't synced yet (an agent filed it
///    seconds ago, or it belongs to another conversation whose items were
///    never fetched).
/// 3. Still missing → `.notSynced`; a throwing store read or refresh →
///    `.failed`.
///
/// What the caller must do with `.notSynced` / `.failed` is as important as
/// the lookup: **stay exactly where you are** and show the message from
/// `Resolution.alertMessage(num:)`. The pre-fix behaviour (pop or replace
/// navigation with the tracker list) destroyed the reader's place in a
/// conversation to show them a list that, by definition, does not contain
/// the item they asked for.
///
/// `resolve` is nonisolated `async`, so the store read happens off the main
/// actor even though `JournalStore`'s API is synchronous.
public struct TrackerItemLinkResolver: Sendable {

    public enum Resolution {
        /// The item is on this device — its id, ready to navigate to.
        case open(String)
        /// A well-formed number that isn't in the local store, even after a
        /// refresh. Either it doesn't exist or it belongs to a journal this
        /// device isn't signed in to.
        case notSynced
        /// The store read or the refresh threw.
        case failed(Error)
    }

    private let lookup: @Sendable (Int) throws -> TrackerItem?
    private let refreshAll: @Sendable () async throws -> Void

    /// Production wiring: the session's `JournalStore` and its `ItemsSync`.
    public init(store: any TrackerItemNumberReading, sync: any ItemsSyncing) {
        self.lookup = { try store.item(num: $0) }
        // `ItemsSync.refresh` swallows its own transport errors (it drives a
        // banner, not a throw), so in production `.failed` only ever comes
        // from the store read. The seam is `throws` anyway so a future
        // throwing refresh — or a test — lands in `.failed` rather than
        // silently reporting `.notSynced` for a network fault.
        self.refreshAll = { await sync.refresh(scope: .all) }
    }

    /// Seam init for tests.
    public init(lookup: @escaping @Sendable (Int) throws -> TrackerItem?,
                refreshAll: @escaping @Sendable () async throws -> Void) {
        self.lookup = lookup
        self.refreshAll = refreshAll
    }

    public func resolve(num: Int) async -> Resolution {
        do {
            if let item = try lookup(num) { return .open(item.id) }
        } catch {
            return .failed(error)
        }
        // One retry, never more: a number that is still missing after a full
        // refresh is not going to appear on a second one, and a link tap
        // must not be able to queue an unbounded run of fetches.
        do {
            try await refreshAll()
        } catch {
            return .failed(error)
        }
        do {
            if let item = try lookup(num) { return .open(item.id) }
            return .notSynced
        } catch {
            return .failed(error)
        }
    }
}

extension TrackerItemLinkResolver.Resolution {
    /// What to put in the host's tracker alert, or `nil` when the item
    /// opened and there is nothing to say.
    public func alertMessage(num: Int) -> String? {
        switch self {
        case .open:
            return nil
        case .notSynced:
            return "Item #\(num) isn't on this device yet."
        case .failed(let error):
            return "Couldn't open item #\(num) — \(error.localizedDescription)"
        }
    }
}
