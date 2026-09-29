import SwiftUI
import XCTest
@testable import MatronDesignSystem
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

    // MARK: - Rendering

    private struct Pixels {
        let image: CGImage
        let scale: CGFloat
        /// x of every column holding a non-white pixel, ascending.
        var inkedColumns: [Int] {
            let width = image.width, height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return (0..<width).filter { x in
                (0..<height).contains { y in
                    let o = (y * width + x) * 4
                    return Int(buffer[o]) + Int(buffer[o + 1]) + Int(buffer[o + 2]) < 3 * 235
                }
            }
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
