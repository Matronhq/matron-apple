import Foundation

/// Tiny, ordered, fixed-capacity cache. Insertions and lookups update
/// recency; once `count > limit`, the least-recently-used entry is
/// evicted. Implementation is an `Array` of keys (recency-ordered, MRU
/// last) plus a `Dictionary` of values — O(n) lookups for the recency
/// move, but `n` is bounded by `limit`, so this is cheap and avoids
/// pulling in `OrderedCollections`.
///
/// Round-5 bugbot finding #3: previously duplicated verbatim between
/// `Matron/App/AppDependencies.swift` and `MatronMac/App/AppDependencies.swift`
/// (~50 lines each, including the `mutating get` subscript and eviction
/// loop). Hoisted into `MatronStorage` so a future eviction-logic fix
/// applies to both targets at once. Both AppDependencies now import this
/// type via `MatronStorage`.
///
/// Not implicitly `Sendable` — callers (currently the `@MainActor`-isolated
/// `AppDependencies` in each app target) provide their own actor isolation.
/// `NSCache` was the alternative but it requires bridging `Hashable` keys
/// to `NSObject` and can evict opaquely on memory pressure, which would
/// break the tight LRU bound assertions in `AppDependenciesTests` /
/// `LRUCacheTests`.
public struct LRUCache<Key: Hashable, Value> {
    private let limit: Int
    private var values: [Key: Value] = [:]
    private var recency: [Key] = []

    public init(limit: Int) {
        precondition(limit > 0, "LRU limit must be positive")
        self.limit = limit
    }

    public var count: Int { values.count }

    public func contains(_ key: Key) -> Bool { values[key] != nil }

    public subscript(key: Key) -> Value? {
        mutating get {
            guard let value = values[key] else { return nil }
            // Touch — move to MRU end so this entry survives the next
            // eviction.
            if let i = recency.firstIndex(of: key) {
                recency.remove(at: i)
            }
            recency.append(key)
            return value
        }
        set {
            if let newValue {
                if values[key] == nil {
                    recency.append(key)
                } else if let i = recency.firstIndex(of: key) {
                    // Existing key — touch to MRU.
                    recency.remove(at: i)
                    recency.append(key)
                }
                values[key] = newValue
                while recency.count > limit {
                    let evict = recency.removeFirst()
                    values.removeValue(forKey: evict)
                }
            } else {
                values.removeValue(forKey: key)
                if let i = recency.firstIndex(of: key) {
                    recency.remove(at: i)
                }
            }
        }
    }
}

/// Composite key for per-room timeline caching, shared by both app
/// targets' `AppDependencies.timelineCache`. Round-5 bugbot finding #3
/// extracted this from the duplicated copies in `Matron/App/AppDependencies.swift`
/// and `MatronMac/App/AppDependencies.swift`. Public so the
/// `LRUCache<TimelineCacheKey, TimelineService>` declaration can live in
/// each app target while the type itself is single-sourced.
public struct TimelineCacheKey: Hashable, Sendable {
    public let userID: String
    public let roomID: String

    public init(userID: String, roomID: String) {
        self.userID = userID
        self.roomID = roomID
    }
}
