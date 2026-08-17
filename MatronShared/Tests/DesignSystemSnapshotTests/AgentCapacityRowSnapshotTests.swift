import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem
import MatronModels

/// Pins how the chooser's capacity block distinguishes numbers it just
/// fetched from numbers it read out of the cache while the box is asleep.
/// The clock is frozen so the reset and age captions don't churn between
/// runs (same `fixedNow` idiom as `UsageMetersSnapshotTests`). The captions
/// still render in the machine's locale and time zone, so — as with the
/// usage-meter baselines — these PNGs are only stable on the machine that
/// recorded them; CI skips them via `MATRON_SKIP_SNAPSHOT_TESTS`.
final class AgentCapacityRowSnapshotTests: XCTestCase {
    /// 2026-08-11 08:13 UTC — the session line below resets later the same
    /// day, the weekly one four days out.
    private let now = Date(timeIntervalSince1970: 1_754_900_000)

    private func capacity(expiredWeek: Bool = false) -> BoxCapacity {
        BoxCapacity(
            liveSessions: 2,
            limitLines: [
                LimitLine(id: "session", label: "Current session", percent: 39,
                          resetsAt: now.addingTimeInterval(10 * 3600)),
                LimitLine(id: "week", label: "Current week (all models)", percent: 85,
                          resetsAt: now.addingTimeInterval(expiredWeek ? -2 * 3600 : 4 * 86_400)),
            ],
            accountEmail: "pat@yearbook.com")
    }

    /// `NSHostingView` has no window, so semantic label colors resolve
    /// against the host app's appearance while the canvas stays transparent —
    /// without an opaque backdrop the text records as invisible pixels.
    private func backdropped<V: View>(_ view: V) -> some View {
        #if os(macOS)
        return view.background(Color(nsColor: .windowBackgroundColor))
        #else
        return view.background(Color(uiColor: .systemBackground))
        #endif
    }

    func test_liveVersusCachedBlocks() {
        let view = VStack(alignment: .leading, spacing: 14) {
            // 1. Answering right now: session count, threshold-tinted
            //    percentages, no disclaimer.
            AgentCapacityRowContent(capacity: capacity(), pending: false,
                                    freshness: .live, fixedNow: now)
            // 2. Asleep: no session count (it runs nothing), every percentage
            //    de-emphasised, one age caption for the block.
            AgentCapacityRowContent(capacity: capacity(), pending: false,
                                    freshness: .offline(capturedAt: now.addingTimeInterval(-2 * 3600)),
                                    fixedNow: now)
            // 3. Asleep long enough that a window rolled over: the line keeps
            //    its own "reset" caption and the block still carries exactly
            //    one age caption — the two say different things.
            AgentCapacityRowContent(capacity: capacity(expiredWeek: true), pending: false,
                                    freshness: .offline(capturedAt: now.addingTimeInterval(-5 * 3600)),
                                    fixedNow: now)
            // 4. Connected, reply still in flight.
            AgentCapacityRowContent(capacity: nil, pending: true, freshness: .live, fixedNow: now)
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)

        assertVariants(of: backdropped(view), named: "agent_capacity_live_vs_cached")
    }
}
