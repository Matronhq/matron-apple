#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

/// Local fake mirroring `FakeTimelineForPalette` in
/// `MacComposerPaletteLayoutTests` — the Mac test target is self-contained.
private final class FakeTimelineForWrap: TimelineService, @unchecked Sendable {
    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}
}

/// Regression under test (Dan, 2026-07-15): the grow-then-scroll rework put
/// the `TextField(axis: .vertical)` inside a `ScrollView(.vertical)`, and
/// long lines stopped wrapping — the field kept its single-line ideal width
/// and overflowed horizontally instead of growing downward.
///
/// Like the palette test, this asserts differentially (long input renders
/// TALLER than short input at the same fixed width) rather than against a
/// stored pixel baseline, so it survives cross-macOS rendering drift.
@MainActor
final class MacComposerWrapLayoutTests: XCTestCase {

    private static let width: CGFloat = 480

    /// Measures the composer fixture's fitting height at a fixed width for
    /// the given input, after letting `onGeometryChange` height plumbing
    /// settle for a runloop turn.
    private func composerHeight(input: String, roomID: String) -> CGFloat {
        let vm = ComposerViewModel(
            roomID: roomID,
            timeline: FakeTimelineForWrap(),
            commands: BotCommandCatalog.claudeBridge
        )
        vm.input = input
        let fixture = MacComposerView(viewModel: vm)
            .frame(width: Self.width)
        let host = NSHostingView(rootView: fixture)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        // The input frame tracks measured content height via @State — pick
        // up any post-measurement growth before reading.
        let height = host.fittingSize.height
        window.orderOut(nil)
        return height
    }

    func test_longInput_wrapsIntoMultipleLines() {
        let short = composerHeight(input: "hi", roomID: "!wrap-short:s")
        let long = composerHeight(
            input: String(repeating: "wrap these words onto more lines ", count: 8),
            roomID: "!wrap-long:s"
        )
        // ~260 chars at 480pt wide must wrap to several lines: the composer
        // grows by at least one full line (~18pt at the default body size).
        XCTAssertGreaterThan(
            long, short + 15,
            "long input must wrap and grow the composer vertically (short: \(short), long: \(long))"
        )
    }

    /// The real-usage path: the editor is FOCUSED and the text arrives by
    /// typing (insertion through the focused text view), not by setting the
    /// binding before layout. If the focused editor's container doesn't
    /// track the composer width, typed text scrolls horizontally (no wrap)
    /// even though the static renders above wrap fine.
    func test_typingWhileFocused_wrapsLongLine() {
        let vm = ComposerViewModel(
            roomID: "!focused-wrap:s",
            timeline: FakeTimelineForWrap(),
            commands: BotCommandCatalog.claudeBridge
        )
        let fixture = MacComposerView(viewModel: vm).frame(width: Self.width)
        let host = NSHostingView(rootView: fixture)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        guard let editor = firstTextView(in: host) else {
            return XCTFail("no NSTextView in composer hierarchy")
        }
        let singleLine = host.fittingSize.height
        window.makeFirstResponder(editor)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        editor.insertText(
            String(repeating: "typed words that must wrap while focused ", count: 8),
            replacementRange: NSRange(location: 0, length: 0)
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        let whileFocused = host.fittingSize.height
        window.orderOut(nil)
        XCTAssertGreaterThan(
            whileFocused, singleLine + 15,
            "focused typing must wrap and grow the composer (single: \(singleLine), focused: \(whileFocused))"
        )
    }

    /// Dan, 2026-07-16: start a message in a WIDE window, then drag the
    /// window NARROWER — the text stopped reflowing and got clipped/hidden
    /// instead of rewrapping onto more lines. The fixed-width tests above
    /// never change width after first layout, so they stayed green while the
    /// resize path broke. Renders long text wide, then shrinks the host to a
    /// narrow width and asserts the composer grows TALLER (rewrapped).
    func test_narrowingWidth_reflowsText_growingTaller() {
        let vm = ComposerViewModel(
            roomID: "!reflow:s",
            timeline: FakeTimelineForWrap(),
            commands: BotCommandCatalog.claudeBridge
        )
        vm.input = String(repeating: "reflow these words when the window shrinks ", count: 6)
        let host = NSHostingView(rootView: MacComposerView(viewModel: vm).frame(width: 700))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: host.fittingSize.height)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        let wideHeight = host.fittingSize.height

        // Shrink the fixture to a narrow width — the same words must now wrap
        // onto more lines and the composer must grow to show them all.
        host.rootView = MacComposerView(viewModel: vm).frame(width: 340)
        host.frame = NSRect(x: 0, y: 0, width: 340, height: host.fittingSize.height)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        let narrowHeight = host.fittingSize.height
        window.orderOut(nil)

        XCTAssertGreaterThan(
            narrowHeight, wideHeight + 15,
            "narrowing the window must rewrap the text taller, not clip it (wide: \(wideHeight), narrow: \(narrowHeight))"
        )
    }

    /// The exact live path Dan hit: the editor is FOCUSED, you've typed a
    /// long line, THEN you drag the window narrower. The focused editor
    /// must re-wrap to the new width; if its text container doesn't track
    /// the shrinking width, the text is clipped off the right edge instead
    /// of reflowing. (This is what SwiftUI's `TextField(axis: .vertical)`
    /// field editor got wrong — reproduced 64→64 before the `NSTextView`
    /// editor replaced it.) Unlike the unfocused resize test, this keeps
    /// the SAME view tree (no rebuild) so focus is retained across the
    /// width change.
    func test_narrowingWidthWhileFocused_reflowsText() {
        let vm = ComposerViewModel(
            roomID: "!focus-reflow:s",
            timeline: FakeTimelineForWrap(),
            commands: BotCommandCatalog.claudeBridge
        )
        // No fixed .frame(width:) — the composer fills the host, so resizing
        // the host width resizes the editor without rebuilding the view.
        let host = NSHostingView(rootView: MacComposerView(viewModel: vm))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        guard let editor = firstTextView(in: host) else {
            return XCTFail("no NSTextView in composer hierarchy")
        }
        window.makeFirstResponder(editor)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        editor.insertText(
            String(repeating: "typed words that must reflow when the window narrows ", count: 6),
            replacementRange: NSRange(location: 0, length: 0)
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        let wideTextHeight = laidOutTextHeight(editor)

        // Drag the window narrower — same focused editor.
        window.setContentSize(NSSize(width: 340, height: 240))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 240)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        let narrowTextHeight = laidOutTextHeight(editor)
        window.orderOut(nil)

        // The same words at a narrower width must lay out onto MORE lines
        // (taller used rect). If the used height is unchanged, the editor
        // kept its wide text container and the tail of each line is
        // clipped off the right edge — the bug Dan hit.
        XCTAssertGreaterThan(
            narrowTextHeight, wideTextHeight + 15,
            "focused text must reflow onto more lines when narrowed (wide: \(wideTextHeight), narrow: \(narrowTextHeight))"
        )
    }

    /// The height TextKit actually laid the glyphs into — grows as text wraps
    /// onto more lines. Reads the real layout, so it catches an editor
    /// whose frame shrank but whose text container did not (clipped text).
    private func laidOutTextHeight(_ editor: NSTextView) -> CGFloat {
        guard let lm = editor.layoutManager, let tc = editor.textContainer else {
            return editor.frame.height
        }
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc).height
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for sub in view.subviews {
            if let found = firstTextView(in: sub) { return found }
        }
        return nil
    }

    func test_longUnbrokenToken_wrapsMidWord() {
        // A pasted path/URL/token has no spaces — TextKit must fall back to
        // character-level breaking rather than overflowing horizontally.
        let short = composerHeight(input: "hi", roomID: "!token-short:s")
        let token = composerHeight(
            input: "/Users/danbarker/Library/Developer/Xcode/DerivedData/Matron-djxcczdoznrqzzazpztxtbtjtynv/Build/Products/Debug/MatronMac.app/Contents/MacOS/MatronMac--with-a-very-long-suffix-token",
            roomID: "!token-long:s"
        )
        XCTAssertGreaterThan(
            token, short + 15,
            "an unbroken token must break mid-word and grow the composer (short: \(short), token: \(token))"
        )
    }
}
#endif
