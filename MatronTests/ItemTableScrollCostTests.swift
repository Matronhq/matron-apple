import XCTest
import UIKit
import SwiftUI
import MatronDesignSystem
@testable import Matron

/// Scrolling an item thread moves every table in it. A table must then
/// cost about what the same cells cost as plain paragraphs: nothing in it
/// may be worked out again because it moved. MarkdownUI's own table view
/// is: to draw its borders and row backgrounds every cell publishes an
/// anchor, and two geometry readers per table resolve all of them again on
/// each scroll frame — for every table in the thread, on screen or not, as
/// the thread is laid out whole. `Theme.matronItem` draws its own grid.
@MainActor
final class ItemTableScrollCostTests: XCTestCase {
    private static let rows = 12
    private static let cells = ["Part", "A long enough cell to wrap once it is capped at its width", "12.5", "**ok**"]

    private static var table: String {
        let row = "| " + cells.joined(separator: " | ") + " |"
        return ([row, "| :--- | :--- | ---: | :---: |"] + Array(repeating: row, count: rows)).joined(separator: "\n")
    }

    /// The same cells, one paragraph each.
    private static var paragraphs: String {
        Array(repeating: cells.joined(separator: "\n\n"), count: rows + 1).joined(separator: "\n\n")
    }

    /// CPU seconds to scroll 30 copies of `markdown` through 200 frames.
    private func cpuSecondsToScroll(_ markdown: String) throws -> Double {
        let view = ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<30, id: \.self) { _ in
                    MarkdownText(markdown, theme: .matronItem, lineSpacing: ItemTypography.lineSpacing)
                }
            }
            .padding()
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<5 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let scrollView = try XCTUnwrap(ItemThreadScrollPerfHarness.threadScrollView(in: window))
        XCTAssertGreaterThan(scrollView.contentSize.height, 4000, "nothing to scroll")
        let start = TimelinePerfProbe.cpuSeconds()
        for _ in 0..<200 {
            scrollView.contentOffset.y += 20
            // One turn of the run loop is one frame: SwiftUI applies the
            // new offset and commits.
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        return TimelinePerfProbe.cpuSeconds() - start
    }

    func test_scrollingTables_costsAboutWhatScrollingTheirTextDoes() throws {
        // Best of two each, so a busy machine slows both sides alike.
        let text = try min(cpuSecondsToScroll(Self.paragraphs), cpuSecondsToScroll(Self.paragraphs))
        let tables = try min(cpuSecondsToScroll(Self.table), cpuSecondsToScroll(Self.table))
        print(String(format: "ITEMTABLECOST text=%.0fms tables=%.0fms ratio=%.2f", text * 1000, tables * 1000, tables / text))
        // A table is more views than its text, so it costs a few times
        // more to move; worked out again each frame it cost twenty times.
        XCTAssertLessThan(tables, text * 5,
                          "tables are worked out again on every scroll frame")
    }
}
