import Foundation
import MatronModels

/// One gate for the live updates that redraw a window's chrome — the chat
/// list, the Decisions and items lists, the Missions dashboard — so they
/// land together, at most once per `interval`, and never while the user is
/// scrolling.
///
/// Every view model publishes on its own schedule as journal writes land.
/// Each publish was a separate SwiftUI transaction, and each one made the
/// window lay itself out again; a busy account turned that into a stream of
/// main-thread stalls, worst while scrolling. Through the gate, a view
/// model hands over a closure that publishes its newest state. The first
/// one after a quiet spell applies at once; later ones wait for the next
/// flush, the newest per owner and key replacing older ones, and every
/// waiting owner applies in that one flush.
///
/// A hold (`beginHold`/`endHold`, the Mac app's live-scroll watcher) parks
/// everything until the last hold ends, then flushes. A hold that never
/// ends — a missed end-of-scroll — still lets updates through every
/// `maxHold`.
@MainActor
public final class LiveUpdateGate {
    public static let shared = LiveUpdateGate()

    private struct Key: Hashable {
        let owner: ObjectIdentifier
        let name: String
    }

    private struct Pending {
        weak var owner: AnyObject?
        let apply: @MainActor () -> Void
    }

    private let interval: Duration
    private let maxHold: Duration
    private var pending: [Key: Pending] = [:]
    private var order: [Key] = []
    private var lastFlush: ContinuousClock.Instant?
    private var flushTask: Task<Void, Never>?
    private var holds = 0
    private var holdTask: Task<Void, Never>?

    /// Flushes that applied at least one update.
    public private(set) var flushCount = 0
    public var isHeld: Bool { holds > 0 }

    public init(interval: Duration = .milliseconds(500), maxHold: Duration = .seconds(4)) {
        self.interval = interval
        self.maxHold = maxHold
    }

    /// Publishes `apply` now, or with the next flush. A later submit for
    /// the same `owner` and `key` replaces this one; `apply` is dropped if
    /// `owner` is gone by then.
    public func submit(_ owner: AnyObject, _ key: String, _ apply: @escaping @MainActor () -> Void) {
        let id = Key(owner: ObjectIdentifier(owner), name: key)
        if pending[id] == nil { order.append(id) }
        pending[id] = Pending(owner: owner, apply: apply)
        guard holds == 0 else { return }
        let now = ContinuousClock.now
        if let lastFlush, now - lastFlush < interval {
            scheduleFlush(after: interval - (now - lastFlush))
        } else {
            flush()
        }
    }

    public func beginHold() {
        holds += 1
        guard holds == 1 else { return }
        flushTask?.cancel()
        flushTask = nil
        armHoldCap()
    }

    public func endHold() {
        guard holds > 0 else { return }
        holds -= 1
        guard holds == 0 else { return }
        holdTask?.cancel()
        holdTask = nil
        flush()
    }

    /// Applies every waiting update now, in the order first submitted.
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !order.isEmpty else { return }
        let keys = order
        let waiting = pending
        order = []
        pending = [:]
        lastFlush = .now
        var applied = false
        for key in keys {
            guard let update = waiting[key], update.owner != nil else { continue }
            update.apply()
            applied = true
        }
        if applied {
            flushCount += 1
            StallCauseRecorder.shared.note("LiveUpdateGate.flush")
        }
    }

    private func scheduleFlush(after delay: Duration) {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            guard self.holds == 0 else { return }
            self.flush()
        }
    }

    private func armHoldCap() {
        holdTask?.cancel()
        let cap = maxHold
        holdTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: cap)
                guard let self, !Task.isCancelled, self.holds > 0 else { return }
                self.flush()
            }
        }
    }
}
