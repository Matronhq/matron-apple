import SwiftUI
import XCTest
import MarkdownUI
@testable import MatronDesignSystem

#if os(macOS)
/// Pins that `Theme.matronItem` really renders larger than MarkdownUI's
/// base — by measuring ink, not by reading the theme back. MarkdownUI
/// silently ignores a relative `FontSize(.em(_:))` in a theme's `.text`
/// style (its own absolute base size is applied inside it and resets the
/// scale), which is how the item body stayed at 13pt through two "size
/// bumps" on 2026-09-14 while every snapshot looked plausible.
@MainActor
final class ItemTypographyRenderTests: XCTestCase {
    private let sample = "The quick brown fox jumps over the lazy dog"

    /// Width of the rendered ink of one line, in points.
    private func inkWidth<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: 700, height: 80, alignment: .topLeading).background(Color.white))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
        host.cacheDisplay(in: host.bounds, to: rep)
        var minX = Int.max, maxX = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5 {
                minX = min(minX, x); maxX = max(maxX, x)
            }
        }
        guard maxX >= 0 else { return 0 }
        return CGFloat(maxX - minX + 1) / (CGFloat(rep.pixelsWide) / 700)
    }

    func testItemBodyRendersAtTheItemScaleNotTheBase() {
        let base = inkWidth(MarkdownText(sample, theme: .matron))
        let item = inkWidth(MarkdownText(sample, theme: .matronItem))
        XCTAssertGreaterThan(base, 0)
        // The same face through the same MarkdownUI path scales its ink
        // width with the point size, so `item / base` should be the body
        // scale. SF's per-size tracking moves that ratio by a few percent
        // and differs between OS versions (a 1.25 scale measured 1.26 on a
        // macOS 26 desktop and 1.20 on the CI runner), so allow ±10%: a
        // silently-ignored scale (ratio 1.0) and a double-applied one
        // (ratio 1.56) both stay well outside the band.
        let expected = base * ItemTypography.bodyScale
        XCTAssertEqual(item, expected, accuracy: base * ItemTypography.bodyScale * 0.10, "item body \(item)pt wide vs expected \(expected)pt (base \(base)pt × \(ItemTypography.bodyScale))")
    }

    func testItemBodyIsLargerThanTheMacChatTimeline() {
        let chat = inkWidth(SelectableMessageText(sample))
        let item = inkWidth(MarkdownText(sample, theme: .matronItem))
        XCTAssertGreaterThan(item, chat, "item body \(item)pt should render wider than the chat timeline's \(chat)pt")
    }
}
#endif
