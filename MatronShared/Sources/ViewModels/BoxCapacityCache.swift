import Foundation
import MatronModels

/// A box's capacity as it was last observed, paired with the moment it was
/// captured. The age is what lets a row say how old its numbers are instead
/// of presenting a week-old percentage as current.
public struct CachedBoxCapacity: Equatable, Sendable {
    public let capacity: BoxCapacity
    public let capturedAt: Date

    public init(capacity: BoxCapacity, capturedAt: Date) {
        self.capacity = capacity
        self.capturedAt = capturedAt
    }
}

/// Last-known capacity per agent box, outliving both the view model and the
/// app process: the host now suspends idle boxes, so the chooser has to be
/// able to show which *offline* box has quota left without being able to ask
/// it. Keyed by agent device id, which is stable within a journal.
///
/// Injected so tests run against an in-memory double; production uses
/// `UserDefaultsBoxCapacityCache`. Display-only, like everything else in the
/// capacity path — a cache miss costs a quieter row, never a blocked pick.
@MainActor
public protocol BoxCapacityCaching: AnyObject {
    /// Every cached box. Callers decide what is too old to show.
    func loadAll() -> [Int64: CachedBoxCapacity]
    /// Records a box's freshly parsed capacity, replacing any earlier one.
    func save(_ capacity: BoxCapacity, for agentID: Int64, at capturedAt: Date)
    /// Drops every box outside `agentIDs`. The roster is the authority on
    /// which boxes still exist — an unpaired box would otherwise sit in the
    /// cache forever, since nothing will ever refresh or supersede it.
    func prune(keeping agentIDs: Set<Int64>)
}

/// `UserDefaults`-backed `BoxCapacityCaching`: the whole map is one JSON
/// blob under a single key, rewritten on every mutation (a fleet is a
/// handful of boxes, so there is nothing to gain from finer granularity).
///
/// The `UserDefaults` instance is injected (defaulting to `.standard`) purely
/// so tests can point it at a throwaway suite, exactly as
/// `RecentStartFolders` does; production always uses the standard domain.
@MainActor
public final class UserDefaultsBoxCapacityCache: BoxCapacityCaching {
    /// One blob per account. Namespacing by user id is not optional
    /// bookkeeping: agent device ids are only unique **within a journal**, so
    /// two accounts on the same device both allocate boxes 1, 2, 3. A shared
    /// key would render account A's account email and quota on account B's
    /// box of the same number — the separation `signOut()` already enforces
    /// by wiping the store, the outbox and the search index, which is why it
    /// removes this key too.
    /// `nonisolated` so the init and `removeAll(for:)` can both reach it.
    nonisolated static func defaultsKey(for userID: String) -> String {
        "newChat.boxCapacityCache.\(userID)"
    }

    private let defaults: UserDefaults
    private let key: String

    /// `nonisolated` so a SwiftUI view's init can build one at a nonisolated
    /// call site — this only captures the injected (immutable) `defaults`
    /// reference; every read and write of the blob stays main-actor-isolated.
    public nonisolated init(userID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = Self.defaultsKey(for: userID)
    }

    /// Drops one account's cache, leaving every other account's alone.
    /// `nonisolated` because `signOut()` runs its teardown off the main
    /// actor; `UserDefaults` is thread-safe.
    public nonisolated static func removeAll(for userID: String,
                                             defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey(for: userID))
    }

    public func loadAll() -> [Int64: CachedBoxCapacity] {
        guard let data = defaults.data(forKey: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Payload.currentVersion else { return [:] }
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: a corrupt
        // blob carrying the same id twice must degrade, not trap.
        return Dictionary(payload.boxes.map { ($0.id, $0.decoded) }, uniquingKeysWith: { _, last in last })
    }

    public func save(_ capacity: BoxCapacity, for agentID: Int64, at capturedAt: Date) {
        var entries = loadAll()
        entries[agentID] = CachedBoxCapacity(capacity: capacity, capturedAt: capturedAt)
        write(entries)
    }

    public func prune(keeping agentIDs: Set<Int64>) {
        write(loadAll().filter { agentIDs.contains($0.key) })
    }

    private func write(_ entries: [Int64: CachedBoxCapacity]) {
        // Sorted so the stored blob is stable across writes that changed
        // nothing — dictionary order is not.
        let boxes = entries.map { Payload.Box(id: $0.key, entry: $0.value) }.sorted { $0.id < $1.id }
        guard let data = try? JSONEncoder().encode(Payload(version: Payload.currentVersion, boxes: boxes))
        else { return }
        defaults.set(data, forKey: key)
    }

    /// The on-disk shape, deliberately its own type rather than a `Codable`
    /// conformance on `BoxCapacity`: that model mirrors the bridge's wire
    /// JSON (snake_case keys, every block optional), so a synthesized
    /// conformance would read nothing the bridge actually sends while looking
    /// like it could. Bumping `currentVersion` retires every older payload.
    private struct Payload: Codable {
        static let currentVersion = 1

        let version: Int
        let boxes: [Box]

        struct Box: Codable {
            let id: Int64
            let capturedAt: Double
            let liveSessions: Int?
            let accountEmail: String?
            let lines: [Line]

            init(id: Int64, entry: CachedBoxCapacity) {
                self.id = id
                self.capturedAt = entry.capturedAt.timeIntervalSince1970
                self.liveSessions = entry.capacity.liveSessions
                self.accountEmail = entry.capacity.accountEmail
                self.lines = entry.capacity.limitLines.map(Line.init)
            }

            var decoded: CachedBoxCapacity {
                CachedBoxCapacity(
                    capacity: BoxCapacity(liveSessions: liveSessions,
                                          limitLines: lines.map(\.decoded),
                                          accountEmail: accountEmail),
                    capturedAt: Date(timeIntervalSince1970: capturedAt))
            }
        }

        struct Line: Codable {
            let id: String
            let label: String
            let percent: Int
            /// Absent, not zero, when the bridge sent no `resets_at`.
            let resetsAt: Double?

            init(_ line: LimitLine) {
                self.id = line.id
                self.label = line.label
                self.percent = line.percent
                self.resetsAt = line.resetsAt?.timeIntervalSince1970
            }

            var decoded: LimitLine {
                LimitLine(id: id, label: label, percent: percent,
                          resetsAt: resetsAt.map(Date.init(timeIntervalSince1970:)))
            }
        }
    }
}
