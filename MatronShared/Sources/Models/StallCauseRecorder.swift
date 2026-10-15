import Foundation
import os

/// What changed just before and during a main-thread stall, so a
/// `main-stall` log line names its cause instead of only its length.
///
/// View models note each property they publish ("ChatList.groups") and the
/// heavy views note each body they evaluate ("Window.body"). A note is a
/// timestamp and a static label written into a fixed ring under a lock:
/// no allocation, cheap enough to leave on in every build.
/// `MainThreadStallMonitor` reads back the notes that landed between one
/// ping interval before its late ping was sent and the moment it ran.
public final class StallCauseRecorder: @unchecked Sendable {
    public static let shared = StallCauseRecorder()

    private struct Note { var at: UInt64; var label: StaticString }

    private let lock = OSAllocatedUnfairLock()
    private var ring: [Note]
    private var next = 0
    private var filled = false
    private var tally: [String: Int]?

    public init(capacity: Int = 512) {
        ring = Array(repeating: Note(at: 0, label: ""), count: max(1, capacity))
    }

    /// Records `label` now (uptime nanoseconds, the monitor's clock).
    public func note(_ label: StaticString) {
        note(label, at: DispatchTime.now().uptimeNanoseconds)
    }

    func note(_ label: StaticString, at time: UInt64) {
        lock.lock()
        ring[next] = Note(at: time, label: label)
        next += 1
        if next == ring.count { next = 0; filled = true }
        if tally != nil { tally![label.description, default: 0] += 1 }
        lock.unlock()
    }

    /// Counts every note from now until `endTally()`, for a perf harness
    /// that needs whole-run totals the ring is too small to hold.
    public func beginTally() {
        lock.lock(); tally = [:]; lock.unlock()
    }

    public func endTally() -> [String: Int] {
        lock.lock(); defer { tally = nil; lock.unlock() }
        return tally ?? [:]
    }

    /// The labels noted in `from...to`, counted, most frequent first
    /// ("ChatList.groups×2, Window.body×1"). Says so when the ring had
    /// already overwritten notes that might have fallen in the window.
    public func summary(from: UInt64, to: UInt64) -> String {
        lock.lock()
        let notes = filled ? Array(ring[next...] + ring[..<next]) : Array(ring[..<next])
        let lost = filled && (notes.first?.at ?? 0) > from
        lock.unlock()
        var counts: [String: Int] = [:]
        var order: [String] = []
        for note in notes where note.at >= from && note.at <= to {
            let label = note.label.description
            if counts[label] == nil { order.append(label) }
            counts[label, default: 0] += 1
        }
        guard !order.isEmpty else { return "nothing recorded" }
        let ranked = order.enumerated()
            .sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }
            .map { "\($0.element)×\(counts[$0.element]!)" }
        return ranked.joined(separator: ", ") + (lost ? " (+ older notes overwritten)" : "")
    }
}
