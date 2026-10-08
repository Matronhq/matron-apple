#if os(macOS)
import SwiftUI
import XCTest
@testable import MatronMac
import MatronJournal

/// App shell (spec §5): the big-icon navigation column to the left of the
/// conversations list. Pure view, so the baselines need no VM.
final class MacNavColumnSnapshotTests: XCTestCase {
    @MainActor
    func testBadge() {
        let view = MacNavColumn(selection: .constant(.decisions), badges: [.decisions: 4])
            .frame(height: 320)
        assertVariants(of: view, named: "MacNavColumn_badge")
    }

    @MainActor
    func testNoBadge() {
        let view = MacNavColumn(selection: .constant(.conversations), badges: [:])
            .frame(height: 320)
        assertVariants(of: view, named: "MacNavColumn_noBadge")
    }

    /// Pinned desk chats under the Coordinator (journal "Pinned desk
    /// chats"): an emoji pin with both badges, a letter pin offering a
    /// successor, and a missing pin greyed out; the Coordinator carries its
    /// needs-you count too.
    @MainActor
    func testPinnedDesks() {
        let pins = [
            ConvoPin(convoID: "c1", label: "Inbox triage", emoji: "📮"),
            ConvoPin(convoID: "c2", label: "mail", emoji: "",
                     successor: ConvoPinSuccessor(convoID: "c9", title: "New")),
            ConvoPin(convoID: "c3", label: "Prod query", emoji: "🔎", missing: true),
        ]
        let view = MacNavColumn(selection: .constant(.desk("c1")),
                                badges: [.coordinator: 2, .desk("c1"): 3, .desk("c3"): 9],
                                needsYou: [.coordinator: 1, .desk("c1"): 2],
                                pins: pins, successorHints: ["c2": "New session on docs-box — move pin here?"])
            .frame(height: 520)
        assertVariants(of: view, named: "MacNavColumn_pinnedDesks")
    }

    func testEntriesInBarOrder() {
        XCTAssertEqual(MacNav.allCases, [.coordinator, .missions, .decisions, .conversations, .memories])
        XCTAssertEqual(MacNav.decisions.title, "For you")
        XCTAssertEqual(MacNav.decisions.symbol, "tray")
        XCTAssertEqual(MacNavColumn.width, 72)
    }
}
#endif
