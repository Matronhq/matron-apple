#if os(macOS)
import XCTest
import SnapshotTesting
import SwiftUI
import MatronChat       // ConversationSummaryEntry
@testable import MatronMac

final class MacSummariesPanelSnapshotTests: XCTestCase {
    @MainActor
    func testSummariesPanelPopulated() {
        let entries = [
            ConversationSummaryEntry(seq: 40, toc: "Shipped the fix", detail: "Working on release.", date: .init(timeIntervalSince1970: 1_770_000_000)),
            ConversationSummaryEntry(seq: 10, toc: "Diagnosed the bug", detail: "", date: .init(timeIntervalSince1970: 1_769_000_000)),
        ]
        let view = MacSummariesPanel(entries: entries, onSelect: { _ in })
            .frame(width: 360, height: 420)
        assertVariants(of: view, named: "MacSummariesPanel_populated")
    }

    @MainActor
    func testSummariesPanelEmpty() {
        let view = MacSummariesPanel(entries: [], onSelect: { _ in })
            .frame(width: 360, height: 420)
        assertVariants(of: view, named: "MacSummariesPanel_empty")
    }
}
#endif
