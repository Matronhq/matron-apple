import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem
import MatronModels

/// `resetDisplay`'s far-future branch ("EEE ha") renders in the machine's
/// local time zone (Task 4's `resetDisplay(... timeZone: .current)`
/// default), so the weekday/hour text these snapshots embed is only
/// stable on the machine that recorded them — same constraint DiffCard's
/// baselines already accept for locally recorded/verified PNGs. Every
/// case here pins its clock to either a fixed offset from `fixedNow` or a
/// raw-string fallback so the countdown/weekday text doesn't churn between
/// runs on this machine.
final class UsageMetersSnapshotTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)

    private func limit(_ label: String, _ percent: Int, resets: String? = nil, resetsAt: Date? = nil) -> SessionStatus.Limit {
        SessionStatus.Limit(label: label, percent: percent, resets: resets, resetsAt: resetsAt)
    }

    func test_contextGauge() {
        assertVariants(
            of: ContextGaugeLabel(context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27))
                .padding(8),
            named: "context_gauge")
    }

    func test_bars_compact_threeColors() {
        let limits = [
            limit("Session", 39, resetsAt: fixedNow.addingTimeInterval(3 * 3600 + 20 * 60)),
            limit("Week (all models)", 66, resetsAt: fixedNow.addingTimeInterval(2 * 24 * 3600)),
            limit("Week (Fable)", 100, resetsAt: fixedNow.addingTimeInterval(2 * 24 * 3600)),
        ]
        assertVariants(
            of: UsageBarsView(limits: limits, scale: .compact, fixedNow: fixedNow).padding(8),
            named: "bars_compact")
    }

    func test_bars_regular() {
        let limits = [
            limit("Session", 12, resetsAt: fixedNow.addingTimeInterval(45 * 60)),
            limit("Week (all models)", 55, resetsAt: fixedNow.addingTimeInterval(3 * 24 * 3600)),
            limit("Week (Fable)", 81, resetsAt: fixedNow.addingTimeInterval(3 * 24 * 3600)),
        ]
        assertVariants(
            of: UsageBarsView(limits: limits, scale: .regular, fixedNow: fixedNow)
                .padding(12).frame(width: 340),
            named: "bars_regular")
    }

    func test_bars_rawStringFallback() {
        let limits = [limit("Session", 39, resets: "Jul 9, 12:59am (UTC)")]
        assertVariants(
            of: UsageBarsView(limits: limits, scale: .regular, fixedNow: fixedNow)
                .padding(12),
            named: "bars_raw_fallback")
    }
}
