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
/// 3. Still missing → `.notSynced`. A throwing store read → `.failed`. A
///    refresh that reported `.failed` gets ONE more local lookup before
///    reporting the failure: `ItemsSync.refreshOnce` upserts each page as
///    it fetches, so a later-page error can still leave an earlier page's
///    item — including the one tapped — already in the store (item #115
///    fix round 6). Only a miss on THAT lookup too becomes `.failed`.
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
        /// The store read threw, or the refresh came back `.failed` —
        /// i.e. we genuinely do not know whether this item exists.
        case failed(Error)
    }

    private let lookup: @Sendable (Int) throws -> TrackerItem?
    private let refreshAll: @Sendable () async -> ItemsRefreshOutcome

    /// Production wiring: the session's `JournalStore` and its `ItemsSync`.
    public init(store: any TrackerItemNumberReading, sync: any ItemsSyncing) {
        self.lookup = { try store.item(num: $0) }
        // `ItemsSync.refresh` still swallows its own transport errors as far
        // as its OWN callers are concerned (it drives a banner, not a
        // throw) — but since item #115 fix round 5 it REPORTS them, which is
        // what stops a failed fetch here from being read as "no such item".
        self.refreshAll = { await sync.refresh(scope: .all) }
    }

    /// Seam init for tests.
    public init(lookup: @escaping @Sendable (Int) throws -> TrackerItem?,
                refreshAll: @escaping @Sendable () async -> ItemsRefreshOutcome) {
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
        //
        // The OUTCOME of that refresh decides what a second miss means. A
        // refresh that failed (offline, 500) leaves the store exactly as
        // stale as it was, so "isn't on this device yet" would be a
        // fabrication — report the failure instead. `.unsupported` (this
        // journal has no tracker) and `.stopped` (sign-out mid-tap) both
        // leave a genuine local miss, so they fall through to `.notSynced`.
        switch await refreshAll() {
        case .failed(let failure):
            // `ItemsSync.refreshOnce` upserts each page as it arrives and
            // only THEN fetches the next, so a later page erroring (the
            // failure this case reports) can still have landed the tapped
            // item from an earlier page before the fetch gave out. Check
            // the store before reporting failure — a tap that already
            // succeeded locally must not show the user a false miss
            // (Bugbot, item #115 fix round 6).
            do {
                if let item = try lookup(num) { return .open(item.id) }
            } catch {
                return .failed(error)
            }
            return .failed(failure)
        case .succeeded, .unsupported, .stopped:
            break
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
