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
        let columns = BoxCapacity.limitColumns(across: [full, partial])

        let view = VStack(alignment: .leading, spacing: 10) {
            MacAgentPickerHeader(columns: columns)
            // 1. Everything the bridge can send.
            MacAgentPickerRow(agent: agent(1, "studio-mac", connected: true),
                              capacity: full, pending: false, columns: columns, fixedNow: now)
            // 2. Missing one fleet column → em-dash cell.
            MacAgentPickerRow(agent: agent(2, "build-7", connected: true),
                              capacity: partial, pending: false, columns: columns, fixedNow: now)
            // 3. Connected, capacity still in flight.
            MacAgentPickerRow(agent: agent(3, "dev-2", connected: true),
                              capacity: nil, pending: true, columns: columns, fixedNow: now)
            // 4. Connected box on an old bridge — no capacity blocks at all.
            MacAgentPickerRow(agent: agent(4, "old-bridge", connected: true),
                              capacity: nil, pending: false, columns: columns, fixedNow: now)
            // 5. Offline: em-dash cells, caption unchanged.
            MacAgentPickerRow(agent: agent(5, "sleeping-box", connected: false),
                              capacity: nil, pending: false, columns: columns, fixedNow: now)
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
}
#endif
