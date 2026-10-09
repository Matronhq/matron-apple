import SwiftUI
import XCTest
@testable import MatronDesignSystem
import MarkdownUI
#if canImport(UIKit) && !os(macOS)
import SnapshotTesting
import UIKit
#endif

/// `Theme.matronItem` tables (item bodies and comments on iOS): a table
/// wider than the card scrolls sideways instead of squeezing its columns
/// into the card width, and a narrow table sits at the card's leading edge
/// inside its horizontal scroll view. MarkdownUI's default table crushed
/// four columns into a phone card and broke words mid-word.
@MainActor
final class ItemTableLayoutTests: XCTestCase {
    private static let wideTable = """
    | Batch | Dry run | Real run | Re-check |
    |---|---|---|---|
    | 31205 Harlaw | would backfill 72 | backfilled 72, cost re-snapshotted as v3 | nothing to backfill |
    | 31240 Freemen's | would backfill 96 | backfilled 96, cost re-snapshotted as v3 | nothing to backfill |
    """

    private static let narrowTable = """
    | K | V |
    |---|---|
    | a | 1 |
    """

    private func body(_ markdown: String) -> some View {
        MarkdownText(markdown, theme: .matronItem, lineSpacing: ItemTypography.lineSpacing)
    }

    private func height(_ markdown: String, width: CGFloat) -> CGFloat {
        #if os(macOS)
        let host = NSHostingController(rootView: body(markdown).frame(width: width))
        #else
        let host = UIHostingController(rootView: body(markdown).frame(width: width))
        #endif
        return host.sizeThatFits(in: CGSize(width: width, height: .infinity)).height
    }

    /// Squeezed columns wrap every cell into several lines; a scrolling
    /// table keeps its natural row heights whatever the card width.
    func test_wideTable_scrollsInsteadOfSqueezing() {
        let narrowCard = height(Self.wideTable, width: 300)
        let wideCard = height(Self.wideTable, width: 1400)
        XCTAssertEqual(narrowCard, wideCard, accuracy: 1,
                       "the table reflowed to the card width instead of scrolling")
    }

    /// A long cell wraps at `ItemTypography.tableCellMaxWidth` instead of
    /// running out on one line: two rows of a single long cell are taller
    /// than two rows of a short one.
    func test_longCell_wrapsAtTheCellCap() {
        let long = "| H |\n|---|\n| " + String(repeating: "word ", count: 60) + "|"
        let short = "| H |\n|---|\n| word |"
        XCTAssertGreaterThan(height(long, width: 1400), height(short, width: 1400) + 20)
    }

    /// A table narrower than the card starts at the card's leading edge —
    /// its left border in the first few points, its right edge well short
    /// of the card's.
    func test_narrowTable_isLeadingAligned() throws {
        let width: CGFloat = 360
        let pixels = try render(body(Self.narrowTable).frame(width: width, alignment: .leading)
            .padding(.vertical, 8).background(Color.white))
        let inked = pixels.inkedColumns
        guard let left = inked.first, let right = inked.last else { return XCTFail("nothing drawn") }
        XCTAssertLessThan(CGFloat(left) / pixels.scale, 4, "table not at the leading edge")
        XCTAssertLessThan(CGFloat(right) / pixels.scale, width / 2, "narrow table stretched or centred")
    }

    /// The delimiter row is what MarkdownUI's `renderMarkdown()` gives the
    /// table style back; parse it into per-column alignments.
    func test_columnAlignments_parseTheDelimiterRow() {
        let parsed = ItemTableColumnAlignment.columns(ofTableMarkdown:
            MarkdownContent("| A | B | C | D |\n|:---|:---:|---:|---|\n| 1 | 2 | 3 | 4 |").renderMarkdown())
        XCTAssertEqual(parsed, [.leading, .center, .trailing, .leading])
        XCTAssertEqual(ItemTableColumnAlignment.columns(ofTableMarkdown: "no table"), [])
    }

    /// GFM column alignment is honoured: a short body cell under a wide
    /// header renders at the column's left, middle or right. Only the body
    /// glyph moves between the three renders (the header fills the column),
    /// so the columns where the renders differ locate it.
    func test_columnAlignment_movesTheCellText() throws {
        func table(_ delimiter: String) -> String { "| A much wider header |\n|\(delimiter)|\n| 7 |" }
        func render(_ delimiter: String) throws -> Pixels {
            try self.render(body(table(delimiter)).frame(width: 360, alignment: .leading)
                .padding(.vertical, 8).background(Color.white))
        }
        let leftRender = try render(":---")
        let width = leftRender.image.width
        let left = leftRender.inkedPixels, center = try render(":---:").inkedPixels, right = try render("---:").inkedPixels
        // The header fills its column and renders identically in all three;
        // the pixels only one render inks are that render's body glyph.
        func meanX(_ pixels: Set<Int>) -> Double {
            pixels.isEmpty ? .nan : Double(pixels.reduce(0) { $0 + $1 % width }) / Double(pixels.count)
        }
        let leftGlyph = meanX(left.subtracting(center).subtracting(right))
        let centerGlyph = meanX(center.subtracting(left).subtracting(right))
        let rightGlyph = meanX(right.subtracting(left).subtracting(center))
        XCTAssertLessThan(leftGlyph, centerGlyph, "centred cell not right of the leading one")
        XCTAssertLessThan(centerGlyph, rightGlyph, "trailing cell not right of the centred one")
    }

    // MARK: - The table read back from its markdown

    private func table(_ markdown: String) -> ItemTable {
        ItemTable(tableMarkdown: MarkdownContent(markdown).renderMarkdown())
    }

    func test_table_readsItsRowsAndAlignments() {
        let parsed = table("| A | B | C |\n|:---|:---:|---:|\n| 1 | **two** | `3` |\n| x | | [l](https://example.com) |")
        XCTAssertEqual(parsed.alignments, [.leading, .center, .trailing])
        XCTAssertEqual(parsed.rows, [["A", "B", "C"], ["1", "**two**", "`3`"], ["x", "", "[l](https://example.com)"]])
    }

    /// A pipe inside a cell is escaped in the source and is a plain pipe in
    /// the cell; other escapes stay for the cell's own markdown.
    func test_table_keepsAnEscapedPipeInsideItsCell() {
        let parsed = table("| A | B |\n|---|---|\n| a \\| b | `x \\| y` |\n| 2 \\* 3 | c |")
        XCTAssertEqual(parsed.rows[1], ["a | b", "`x | y`"])
        XCTAssertEqual(parsed.rows[2], ["2 \\* 3", "c"])
    }

    func test_table_givesEveryRowOneCellPerColumn() {
        let parsed = table("| A | B | C |\n|---|---|---|\n| only |\n| 1 | 2 | 3 | 4 |")
        XCTAssertEqual(parsed.rows.map(\.count), [3, 3, 3])
        XCTAssertEqual(parsed.rows[1], ["only", "", ""])
    }

    /// A cell is inline text in its table; parsed alone, one that starts
    /// like a block must stay the text it was.
    func test_cellMarkdown_neverParsesAsABlock() {
        for cell in ["# of rows", "###", "- none", "-", "+ 3", "* starred", "1. first", "12) twelfth", "> 5", ">5",
                     "---", "***", "___", "~~~", "```", "[note]: see below"] {
            let rendered = MarkdownContent(ItemTable.inlineMarkdown(ofCell: cell)).renderPlainText()
            XCTAssertEqual(rendered, cell, "cell \"\(cell)\" did not survive as text")
        }
    }

    func test_cellMarkdown_leavesInlineMarkdownAlone() {
        for cell in ["**bold**", "*em*", "_em_", "`code`", "```code```", "~~gone~~", "[link](https://example.com)",
                     "#12", "-5", "1.5", "2024", "plain"] {
            XCTAssertEqual(ItemTable.inlineMarkdown(ofCell: cell), cell)
        }
    }

    /// An empty cell still holds a line, so a row of blanks keeps its height.
    func test_cellMarkdown_ofAnEmptyCell_isNotEmpty() {
        XCTAssertFalse(ItemTable.inlineMarkdown(ofCell: "").isEmpty)
    }

    /// A cell's inline markdown reaches the screen styled, not as source.
    func test_cell_rendersItsInlineMarkdown() throws {
        let styled = try render(body("| A |\n|---|\n| **bold** `code` |").frame(width: 360, alignment: .leading)
            .padding(.vertical, 8).background(Color.white)).inkedColumns.count
        let source = try render(body("| A |\n|---|\n| \\*\\*bold\\*\\* \\`code\\` |").frame(width: 360, alignment: .leading)
            .padding(.vertical, 8).background(Color.white)).inkedColumns.count
        XCTAssertLessThan(styled, source, "the cell drew its markdown markers")
    }

    // MARK: - Rendering

    private struct Pixels {
        let image: CGImage
        let scale: CGFloat
        /// Every non-white pixel, as `y * width + x`.
        var inkedPixels: Set<Int> {
            let width = image.width, height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var inked = Set<Int>()
            for y in 0..<height { for x in 0..<width {
                let o = (y * width + x) * 4
                if Int(buffer[o]) + Int(buffer[o + 1]) + Int(buffer[o + 2]) < 3 * 235 { inked.insert(y * width + x) }
            } }
            return inked
        }

        /// x of every column holding a non-white pixel, ascending.
        var inkedColumns: [Int] {
            Set(inkedPixels.map { $0 % image.width }).sorted()
        }
    }

    private func render<V: View>(_ view: V) throws -> Pixels {
        #if os(macOS)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Pixels(image: try XCTUnwrap(rep.cgImage), scale: CGFloat(rep.pixelsWide) / host.bounds.width)
        #else
        var captured: UIImage?
        let done = expectation(description: "render")
        Snapshotting<AnyView, UIImage>.image(layout: .sizeThatFits,
                                             traits: .init(userInterfaceStyle: .light))
            .snapshot(AnyView(view)).run { captured = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        let image = try XCTUnwrap(captured)
        return Pixels(image: try XCTUnwrap(image.cgImage), scale: image.scale)
        #endif
    }
}
