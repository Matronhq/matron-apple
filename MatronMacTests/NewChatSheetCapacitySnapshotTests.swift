#if os(macOS)
import XCTest
import SnapshotTesting
import SwiftUI
import MatronJournal   // DeviceDTO
import MatronModels    // BoxCapacity / LimitLine
@testable import MatronMac

/// Pins the three states a New Chat machine row can be in. Rows are
/// rendered directly (no view model, no async) with a frozen clock, so the
/// baselines don't drift with the wall clock or a live RPC.
final class NewChatSheetCapacitySnapshotTests: XCTestCase {
    /// 2026-08-11 08:13 UTC — the session limit below resets later the same
    /// day (time-only caption), the weekly one four days out (dated).
    private let now = Date(timeIntervalSince1970: 1_754_900_000)

    private func agent(_ id: Int64, _ name: String, connected: Bool, lastSeenAt: Int64? = nil) -> DeviceDTO {
        DeviceDTO(id: id, kind: "agent", name: name, createdAt: 0, cursor: 0,
                  lag: 0, lastSeenAt: lastSeenAt, isSelf: false, connected: connected)
    }

    @MainActor
    func testAgentPickerRowStates() {
        let full = BoxCapacity(
            liveSessions: 2,
            limitLines: [
                LimitLine(id: "session", label: "Current session", percent: 39,
                          resetsAt: now.addingTimeInterval(10 * 3600)),
                LimitLine(id: "week", label: "Current week (all models)", percent: 85,
                          resetsAt: now.addingTimeInterval(4 * 86_400)),
            ],
            accountEmail: "pat@yearbook.com")
        // Reports only one of the fleet's two lines — its other cell is "—".
        let partial = BoxCapacity(
            liveSessions: 0,
            limitLines: [
                LimitLine(id: "session", label: "Current session", percent: 92,
                          resetsAt: now.addingTimeInterval(2 * 3600)),
            ],
            accountEmail: nil)
        // Asleep, but its last report is cached: percentages de-emphasised,
        // no session count, and one age caption under the name.
        let cached = BoxCapacity(
            liveSessions: 3,
            limitLines: [
                LimitLine(id: "session", label: "Current session", percent: 12,
                          resetsAt: now.addingTimeInterval(6 * 3600)),
                LimitLine(id: "week", label: "Current week (all models)", percent: 44,
                          resetsAt: now.addingTimeInterval(3 * 86_400)),
            ],
            accountEmail: "sam@yearbook.com")
        let columns = BoxCapacity.limitColumns(across: [full, partial])

        let view = VStack(alignment: .leading, spacing: 10) {
            MacAgentPickerHeader(columns: columns, showsSessions: true)
            // 1. Everything the bridge can send.
            MacAgentPickerRow(agent: agent(1, "studio-mac", connected: true),
                              capacity: full, pending: false, columns: columns, showsCells: true,
                              showsSessions: true, freshness: .live, fixedNow: now)
            // 2. Missing one fleet column → em-dash cell.
            MacAgentPickerRow(agent: agent(2, "build-7", connected: true),
                              capacity: partial, pending: false, columns: columns, showsCells: true,
                              showsSessions: true, freshness: .live, fixedNow: now)
            // 3. Connected, capacity still in flight.
            MacAgentPickerRow(agent: agent(3, "dev-2", connected: true),
                              capacity: nil, pending: true, columns: columns, showsCells: true,
                              showsSessions: true, freshness: .live, fixedNow: now)
            // 4. Connected box on an old bridge — no capacity blocks at all.
            MacAgentPickerRow(agent: agent(4, "old-bridge", connected: true),
                              capacity: nil, pending: false, columns: columns, showsCells: true,
                              showsSessions: true, freshness: .live, fixedNow: now)
            // 5. Offline with nothing cached: em-dash cells, no caption.
            MacAgentPickerRow(agent: agent(5, "sleeping-box", connected: false),
                              capacity: nil, pending: false, columns: columns, showsCells: true,
                              showsSessions: true, freshness: .live, fixedNow: now)
            // 6. Offline with a cached report — the row this feature exists
            //    for: grey percentages, "—" sessions, "offline · as of 2h ago".
            MacAgentPickerRow(agent: agent(6, "asleep-box", connected: false),
                              capacity: cached, pending: false, columns: columns, showsCells: true,
                              showsSessions: true,
                              freshness: .offline(capturedAt: now.addingTimeInterval(-2 * 3600)),
                              fixedNow: now)
        }
        .padding(12)
        .frame(width: 700)
        // Opaque, appearance-derived backdrop: `NSHostingView` has no window
        // here, so label colors resolve against the host app's appearance
        // while the snapshot canvas stays transparent — without this the
        // secondary/primary text records as invisible pixels.
        .background(Color(nsColor: .windowBackgroundColor))

        assertVariants(of: view, named: "MacNewChatAgentRows_states")
    }

    /// An all-legacy fleet: bridges answered `recent_folders` but sent no
    /// capacity blocks, so their parsed capacity is EMPTY. No header, no
    /// data cells — the picker must look exactly like the pre-grid one.
    @MainActor
    func testAgentPickerRowsLegacyFleet() {
        let empty = BoxCapacity(liveSessions: nil, limitLines: [], accountEmail: nil)
        let view = VStack(alignment: .leading, spacing: 10) {
            MacAgentPickerRow(agent: agent(1, "old-a", connected: true),
                              capacity: empty, pending: false, columns: [],
                              showsCells: false, showsSessions: false,
                              freshness: .live, fixedNow: now)
            // Asleep on a legacy bridge: the persisted capacity is EMPTY, so
            // there is nothing cached to disclaim and no caption appears.
            MacAgentPickerRow(agent: agent(2, "old-b", connected: false),
                              capacity: empty, pending: false, columns: [],
                              showsCells: false, showsSessions: false,
                              freshness: .offline(capturedAt: now.addingTimeInterval(-2 * 3600)),
                              fixedNow: now)
        }
        .padding(12)
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))

        assertVariants(of: view, named: "MacNewChatAgentRows_legacy")
    }
}
#endif
