import Foundation
import MatronModels

/// What an index needs to publish `ListUpdate`s for one of its lists: the
/// state it last published, and the ids touched since. Queue-confined to
/// the index, like the rest of its state.
///
/// Nothing is recorded until a first state is published (a subscriber
/// arrived), and `forget()` drops everything when the last one leaves, so
/// an unsubscribed list costs nothing.
struct ListUpdateTracker<ID: Hashable & Sendable> {
    /// The sections the last update carried, or `nil` before the first.
    private(set) var published: [ListSection<ID>]?
    private var touched: Set<ID> = []
    private var needsReset = false

    /// Whether the next `next(_:)` could produce an update.
    var isPending: Bool { published == nil || needsReset || !touched.isEmpty }

    /// Records ids whose row was inserted, removed, moved or changed.
    mutating func touch<S: Sequence>(_ ids: S) where S.Element == ID {
        guard published != nil else { return }
        touched.formUnion(ids)
    }

    /// The source was reloaded: the next update is a reset.
    mutating func reset() {
        guard published != nil else { return }
        needsReset = true
    }

    /// The update from the last published state to `sections`, or `nil`
    /// when nothing changed. The first update, and the first after
    /// `reset()`, is a reset.
    mutating func next(_ sections: [ListSection<ID>]) -> ListUpdate<ID>? {
        defer {
            touched = []
            needsReset = false
        }
        let update: ListUpdate<ID>
        if let published, !needsReset {
            update = ListUpdate(from: published, to: sections, touched: touched)
            guard update.hasChanges else { return nil }
        } else {
            update = .reset(sections)
        }
        published = update.sections
        return update
    }

    /// Drops the published state: the next update is a first one.
    mutating func forget() {
        published = nil
        touched = []
        needsReset = false
    }
}
