import SwiftUI
import XCTest
@testable import MatronDesignSystem

#if os(macOS)
/// The cross-message highlight as the WINDOW SERVER shows it. TextKit 2
/// caches its glyph rendering in private viewport element views, so an
/// offscreen `cacheDisplay` (which redraws every subview) passes while the
/// real window keeps stale pixels. This test orders a window on screen and
/// captures it; it skips on a headless runner where capture is unavailable.
@MainActor
final class MessageCopyTextViewOnScreenTests: XCTestCase {
    func test_highlightAddShrinkAndClearRepaintOnScreen() throws {
        let controller = MessageSelectionController()
        let text = "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog."
        let host = NSHostingView(rootView:
            SelectableMessageText(text, itemID: "a").environment(controller)
                .frame(width: 300, alignment: .topLeading).padding(20).background(Color.white))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 340, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func spin() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3)) }
        spin()
        func find(_ v: NSView) -> MessageCopyTextView? {
            if let t = v as? MessageCopyTextView { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        guard let tv = find(host) else { return XCTFail("no text view") }
        // The highlight colour is the user's accent-dependent selection
        // colour, resolved in this window's appearance — never assume blue.
        var expected = NSColor.selectedTextBackgroundColor
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            expected = NSColor.selectedTextBackgroundColor.usingColorSpace(.sRGB) ?? expected
        }
        let target = (r: expected.redComponent * 255, g: expected.greenComponent * 255, b: expected.blueComponent * 255)
        func highlightPixels() throws -> Int {
            spin()
            guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
                  img.width > 0, let data = img.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else {
                throw XCTSkip("window capture unavailable (headless runner)")
            }
            var n = 0
            for y in 0..<img.height { for x in 0..<img.width {
                let o = y * img.bytesPerRow + x * 4
                let b = CGFloat(ptr[o]), g = CGFloat(ptr[o + 1]), r = CGFloat(ptr[o + 2]) // BGRA
                if abs(r - target.r) < 24, abs(g - target.g) < 24, abs(b - target.b) < 24 { n += 1 }
            } }
            return n
        }
        let before = try highlightPixels()
        tv.setCrossSelection(NSRange(location: 4, length: 60))
        let sixty = try highlightPixels()
        XCTAssertGreaterThan(sixty, before + 500, "highlight did not appear on screen")
        tv.setCrossSelection(NSRange(location: 4, length: 10))
        let ten = try highlightPixels()
        XCTAssertLessThan(ten, sixty / 2, "shrunk highlight did not repaint on screen")
        XCTAssertGreaterThan(ten, before)
        tv.setCrossSelection(nil)
        let cleared = try highlightPixels()
        XCTAssertLessThan(cleared, before + 50, "cleared highlight stayed on screen")
    }
}
#endif
