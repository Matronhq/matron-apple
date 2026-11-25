#if os(macOS)
import XCTest
import SnapshotTesting
import SwiftUI
import MatronJournal   // DeviceDTO
import MatronModels    // BoxCapacity / LimitLine / BoxStatus
@testable import MatronMac

/// Settings ▸ Devices rows at the pane's own width and a narrower one. The
/// action buttons must sit under the details and wrap, so the name, the
/// badges and the usage lines keep the row's full width and never break
/// mid-word.
final class MacDevicesRowSnapshotTests: XCTestCase {
    private func rows() -> some View {
        let capacity = BoxCapacity(
            liveSessions: 0,
            limitLines: [
                LimitLine(id: "session", label: "Current session", percent: 4, resetsAt: nil),
                LimitLine(id: "week", label: "Week (all models)", percent: 33, resetsAt: nil),
            ],
            accountEmail: nil)
        let status = BoxStatus(reportedAt: Date(timeIntervalSince1970: 1_754_900_000), capacity: capacity)
        let protected = DeviceDTO(id: 1, kind: "agent", name: "box-a", createdAt: 0, cursor: 0,
                                  lag: 3_653_365, lastSeenAt: nil, isSelf: false, connected: true,
                                  status: status, isProtected: true)
        let plain = DeviceDTO(id: 2, kind: "agent", name: "build-box-2", createdAt: 0, cursor: 0,
                              lag: 0, lastSeenAt: nil, isSelf: false, connected: true,
                              tagChar: "B", status: status)
        let mac = DeviceDTO(id: 3, kind: "client", name: "alice-mac", createdAt: 0, cursor: 0,
                            lag: 0, lastSeenAt: nil, isSelf: true, connected: true)
        // A long caption: the details take more of the row and the buttons
        // still get the rest.
        let expired = DeviceDTO(id: 4, kind: "client", name: "old-phone", createdAt: 0, cursor: 0,
                                lag: 120, lastSeenAt: nil, isSelf: false, idleExpired: true)
        return List {
            DeviceRow(device: protected, newSessions: "Box default", onEditDefaults: {}, onRevoke: {},
                      onRename: {}, onSetLetter: {}, onToggleProtected: {})
            DeviceRow(device: plain, newSessions: "Claude · Opus · high", onEditDefaults: {}, onRevoke: {},
                      onRename: {}, onSetLetter: {}, onToggleProtected: {})
            DeviceRow(device: mac, newSessions: nil, onEditDefaults: {}, onRevoke: {},
                      onRename: {}, onSetLetter: {}, onToggleProtected: {})
            DeviceRow(device: expired, newSessions: nil, onEditDefaults: {}, onRevoke: {},
                      onRename: {}, onSetLetter: {}, onToggleProtected: {})
        }
    }

    @MainActor
    func testRowsAtPaneWidth() {
        assertVariants(of: rows().frame(width: MacSettingsLayout.paneWidth, height: 440),
                       named: "MacDevicesRows_pane")
    }

    @MainActor
    func testRowsNarrow() {
        assertVariants(of: rows().frame(width: 380, height: 760),
                       named: "MacDevicesRows_narrow")
    }
}
#endif
