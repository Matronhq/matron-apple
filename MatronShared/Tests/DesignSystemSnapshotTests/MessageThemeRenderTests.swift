import SwiftUI
import XCTest
import MarkdownUI
@testable import MatronDesignSystem

#if os(macOS)
/// Pins that `Theme.matronMessage` really is the base size, by measuring
/// ink rather than reading the theme back. `matronMessage` used to set a
/// `FontSize(.em(MessageTextScale.scale))` override claiming ×1.18 (iOS)
/// / ×1.10 (macOS) messages, but MarkdownUI 2.x silently discards a
/// relative `FontSize(.em(_:))` set at a theme's root `.text` style
/// (`Markdown.body` applies `theme.text` outside and then its own
/// absolute `ScaledFontSizeModifier` inside, resetting the relative scale
/// to 1 — see `ItemTypographyRenderTests`, which caught the same bug for
/// `Theme.matronItem`). So the override was a no-op from day one; Dan
/// removed it on 2026-09-14 (#823) rather than making it real, since chat
/// bodies should stay at system size on iOS. This test documents that
/// `matronMessage` and `matron` render identically.
@MainActor
final class MessageThemeRenderTests: XCTestCase {
    private let sample = "Two options"

    /// Width of the rendered ink of one line, in points. Mirrors
    /// `ItemTypographyRenderTests.inkWidth` (that helper is `private`, so
    /// duplicated here rather than exposed just for this test).
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

    func testMatronMessageRendersAtTheBaseSizeNotAScaledOne() {
        let base = inkWidth(MarkdownText(sample, theme: .matron))
        let message = inkWidth(MarkdownText(sample, theme: .matronMessage))
        XCTAssertGreaterThan(base, 0)
        // `matronMessage` is intentionally just `.matron` now (#823): the
        // two should render pixel-for-pixel the same width, well inside a
        // 1px tolerance for rounding. A regression that reintroduces a
        // `.em` scale on `matronMessage`'s `.text` style would either move
        // this (if the scale somehow took effect) or leave it unchanged
        // (proving it's still a no-op) — either way this test calls it out
        // by name rather than letting it hide behind a passing snapshot.
        XCTAssertEqual(message, base, accuracy: 1, "matronMessage \(message)pt wide vs matron \(base)pt — expected the same base size")
    }
}
#endif
