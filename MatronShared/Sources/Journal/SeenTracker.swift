import Foundation
import CoreGraphics
import os

/// Read state (matron-journal protocol.md "Read state", spec
/// 2026-09-30-read-state-design.md): which messages were actually on the
/// user's screen. Separate from `read_marker` and the unread badge, which
/// this never touches.
///
/// A message counts as seen once its row has been visible for `dwell`
/// (1 s) while the app is active. Visible means at least half the row is on
/// screen, or the row covers at least half the viewport
/// (`SeenVisibility`). Seen seqs are batched into ranges and flushed about
/// every 2 s, and at once when the app goes inactive or a chat closes.

/// Which rows count as visible, from their frames and the viewport, in one
/// coordinate space. Shared by the iOS collection view and the Mac stack so
/// both platforms apply the same rule.
public enum SeenVisibility {
    /// Ids of `frames` that are at least half visible in `viewport`, or whose
    /// visible part covers at least half the viewport's height (a row taller
    /// than two screens can never be half visible). Input order is kept.
    public static func visibleIDs<ID>(_ frames: [(id: ID, frame: CGRect)], in viewport: CGRect) -> [ID] {
        guard viewport.height > 0 else { return [] }
        return frames.compactMap { entry in
            let frame = entry.frame
            guard frame.height > 0 else { return nil }
            let top = max(frame.minY, viewport.minY)
            let bottom = min(frame.maxY, viewport.maxY)
            let shown = bottom - top
            guard shown > 0 else { return nil }
            return shown >= frame.height / 2 || shown >= viewport.height / 2 ? entry.id : nil
        }
    }

    /// A timeline row id as a journal seq: message rows are keyed by their
    /// event's seq. Local echoes (`echo:`), the streaming overlay (`eph:`),
    /// separators and other synthetic rows have no seq and are skipped.
    public static func seq(forRowID id: String) -> Int64? {
        guard let seq = Int64(id), seq > 0 else { return nil }
        return seq
    }
}

/// The pure state behind `SeenTracker`: dwell timing, pending seqs and range
/// batching. Time is passed in, so tests drive it with synthetic instants.
public struct SeenLedger {
    public typealias Instant = ContinuousClock.Instant

    /// The journal's cap on ranges per `seen` op.
    public static let maxRangesPerOp = 64

    private struct Surface {
        var convoID: String
        /// Visible seq → when its current dwell started (reset whenever the
        /// app becomes active again).
        var since: [Int64: Instant] = [:]
    }

    public let dwell: Duration
    public private(set) var isActive: Bool
    private var surfaces: [UUID: Surface] = [:]
    /// Seen, not yet sent, per conversation.
    private var pending: [String: Set<Int64>] = [:]
    /// Already sent (or queued) per conversation, so a row that stays on
    /// screen isn't reported on every flush.
    private var reported: [String: Set<Int64>] = [:]

    public init(dwell: Duration = .seconds(1), isActive: Bool = true) {
        self.dwell = dwell
        self.isActive = isActive
    }

    public var hasPending: Bool { !pending.isEmpty }

    /// `surface` now shows `seqs` of `convoID`. Seqs still visible keep their
    /// dwell start; new ones start now; the rest stop counting.
    public mutating func setVisible(surface: UUID, convoID: String, seqs: some Sequence<Int64>, now: Instant) {
        var entry = surfaces[surface].flatMap { $0.convoID == convoID ? $0 : nil } ?? Surface(convoID: convoID)
        var since: [Int64: Instant] = [:]
        for seq in seqs where !(reported[convoID]?.contains(seq) ?? false) {
            since[seq] = entry.since[seq] ?? now
        }
        entry.since = since
        surfaces[surface] = entry
    }

    /// The surface went away (chat closed). Rows that already dwelt long
    /// enough are promoted first.
    public mutating func removeSurface(_ surface: UUID, now: Instant) {
        promote(now: now)
        surfaces[surface] = nil
    }

    /// App (or, on Mac, window) active state. Going inactive promotes what
    /// already dwelt and pauses the rest; becoming active restarts every
    /// visible row's dwell from `now`.
    public mutating func setActive(_ active: Bool, now: Instant) {
        guard active != isActive else { return }
        if !active { promote(now: now) }
        isActive = active
        if active {
            for key in surfaces.keys {
                for seq in surfaces[key]!.since.keys { surfaces[key]!.since[seq] = now }
            }
        }
    }

    /// Marks a seq seen outright, without dwell (a tapped notification).
    public mutating func markSeen(convoID: String, seq: Int64) {
        guard !(reported[convoID]?.contains(seq) ?? false) else { return }
        pending[convoID, default: []].insert(seq)
        reported[convoID, default: []].insert(seq)
    }

    /// Moves every visible seq whose dwell is complete into `pending`.
    public mutating func promote(now: Instant) {
        guard isActive else { return }
        for key in surfaces.keys {
            let convoID = surfaces[key]!.convoID
            for (seq, start) in surfaces[key]!.since where now - start >= dwell {
                surfaces[key]!.since[seq] = nil
                markSeen(convoID: convoID, seq: seq)
            }
        }
    }

    /// When the next dwell completes, or nil when nothing is dwelling.
    public var nextDeadline: Instant? {
        guard isActive else { return nil }
        return surfaces.values.flatMap(\.since.values).min().map { $0 + dwell }
    }

    /// Takes everything pending as `seen` ops: consecutive seqs merged into
    /// ranges, at most `maxRangesPerOp` ranges per op.
    public mutating func drain() -> [ClientOp] {
        defer { pending.removeAll() }
        return pending.keys.sorted().flatMap { convoID -> [ClientOp] in
            let ranges = Self.ranges(pending[convoID]!)
            return stride(from: 0, to: ranges.count, by: Self.maxRangesPerOp).map {
                .seen(convoID: convoID, ranges: Array(ranges[$0..<min($0 + Self.maxRangesPerOp, ranges.count)]))
            }
        }
    }

    /// A drained op failed to send; its seqs go back into `pending`.
    public mutating func restore(_ op: ClientOp) {
        guard case let .seen(convoID, ranges) = op else { return }
        for range in ranges { pending[convoID, default: []].formUnion(range) }
    }

    /// Sorted, with runs of consecutive seqs merged.
    static func ranges(_ seqs: Set<Int64>) -> [ClosedRange<Int64>] {
        var out: [ClosedRange<Int64>] = []
        for seq in seqs.sorted() {
            if let last = out.last, last.upperBound + 1 == seq {
                out[out.count - 1] = last.lowerBound...seq
            } else {
                out.append(seq...seq)
            }
        }
        return out
    }
}

/// Drives a `SeenLedger` on real time and sends through the journal
/// connection (`JournalSyncEngine.sendOp`). One per signed-in session.
@MainActor
public final class SeenTracker {
    public typealias Send = @Sendable (ClientOp) async throws -> Void

    private static let logger = Logger(subsystem: "chat.matron", category: "seen")

    private var ledger: SeenLedger
    private let flushInterval: Duration
    private let send: Send
    private var dwellTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    /// Item details on screen → the newest rendered comment (ms, 0 = none).
    private var itemsOnScreen: [String: Int64] = [:]
    /// The newest comment already reported per item (the op is monotonic
    /// server-side, so re-sending an older value is only wasted bytes).
    private var itemsReported: [String: Int64] = [:]

    public init(dwell: Duration = .seconds(1), flushInterval: Duration = .seconds(2),
                isActive: Bool = true, send: @escaping Send) {
        self.ledger = SeenLedger(dwell: dwell, isActive: isActive)
        self.flushInterval = flushInterval
        self.send = send
    }

    private var now: ContinuousClock.Instant { .now }

    // MARK: Messages

    /// The rows `surface` currently shows as visible (see `SeenVisibility`),
    /// as timeline row ids; ids that aren't journal seqs are ignored.
    public func setVisible(surface: UUID, convoID: String, rowIDs: [String]) {
        let deadline = ledger.nextDeadline
        ledger.setVisible(surface: surface, convoID: convoID,
                          seqs: rowIDs.compactMap(SeenVisibility.seq(forRowID:)), now: now)
        // Scroll ticks mostly leave the next deadline where it was.
        if ledger.nextDeadline != deadline { schedule() }
    }

    /// The surface closed or stopped showing a chat: flush what it saw.
    public func removeSurface(_ surface: UUID) {
        ledger.removeSurface(surface, now: now)
        schedule()
        flush()
    }

    /// A tapped notification showed this message: seen at once.
    public func markSeen(convoID: String, seq: Int64) {
        ledger.markSeen(convoID: convoID, seq: seq)
        flush()
    }

    /// App (and, on Mac, window) foreground state. Going inactive flushes.
    public func setActive(_ active: Bool) {
        ledger.setActive(active, now: now)
        if active {
            for (itemID, through) in itemsOnScreen { reportItem(itemID, through: through) }
        } else {
            flush()
        }
        schedule()
    }

    // MARK: Items

    /// An item's detail is on screen with `newestComment` the newest comment
    /// rendered in its thread (nil when it has none). Sent at once while
    /// active, and again whenever a newer comment renders.
    public func setItemOnScreen(_ itemID: String, newestComment: Date?) {
        let through = newestComment.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
        itemsOnScreen[itemID] = through
        if ledger.isActive { reportItem(itemID, through: through) }
    }

    public func removeItem(_ itemID: String) {
        itemsOnScreen[itemID] = nil
    }

    private func reportItem(_ itemID: String, through: Int64) {
        if let last = itemsReported[itemID], last >= through { return }
        itemsReported[itemID] = through
        let send = send
        Task {
            do {
                try await send(.itemSeen(itemID: itemID, throughCommentAt: through))
            } catch {
                // Offline: forget it was sent, so the next open or active
                // transition reports it again.
                if itemsReported[itemID] == through { itemsReported[itemID] = nil }
            }
        }
    }

    // MARK: Scheduling

    /// Arms the dwell timer for the next row to finish dwelling, and the
    /// flush timer when something is pending.
    private func schedule() {
        dwellTask?.cancel()
        dwellTask = nil
        if let deadline = ledger.nextDeadline {
            dwellTask = Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                self.ledger.promote(now: self.now)
                self.schedule()
            }
        }
        if ledger.hasPending, flushTask == nil {
            let interval = flushInterval
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.flushTask = nil
                self.flush()
            }
        }
    }

    /// Sends everything pending now. Failed sends are kept for the next flush.
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        let ops = ledger.drain()
        guard !ops.isEmpty else { return }
        let send = send
        Task {
            var failed: [ClientOp] = []
            for op in ops {
                do { try await send(op) } catch { failed.append(op) }
            }
            guard !failed.isEmpty else { return }
            Self.logger.info("seen flush deferred: \(failed.count, privacy: .public) op(s) unsent")
            for op in failed { ledger.restore(op) }
            // Offline: the retry rides the next scheduled flush (or the next
            // state change), not a tight loop.
            if ledger.isActive { schedule() }
        }
    }
}
