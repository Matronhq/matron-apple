#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

/// Local fake mirroring `FakeTimelineForPalette` — the Mac test target is
/// self-contained.
private final class FakeTimelineForAccessory: TimelineService, @unchecked Sendable {
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

/// Regression under test (Dan, 2026-07-16): "the text input field changes
/// width as you're typing". The trailing accessory swaps between the mic
/// (empty field, `.title3` glyph) and the send arrow (non-empty, `.title`
/// glyph); the two icons render at different widths, so the input field
/// jumped sideways on the first typed character. Both accessories must
/// occupy the same fixed width so the field's width never depends on
/// which one is showing.
@MainActor
final class MacComposerAccessoryWidthTests: XCTestCase {

    private static let width: CGFloat = 480

    /// Renders the composer at a fixed width and returns the input editor's
    /// rendered width. Finds the editor structurally (an `NSTextField` or
    /// `NSTextView` descendant) so the assertion survives the editor's
    /// SwiftUI-vs-AppKit implementation.
    private func editorWidth(input: String, roomID: String) -> CGFloat {
        let vm = ComposerViewModel(
            roomID: roomID,
            timeline: FakeTimelineForAccessory(),
            commands: BotCommandCatalog.claudeBridge
        )
        vm.input = input
        let host = NSHostingView(
            rootView: MacComposerView(viewModel: vm).frame(width: Self.width)
        )
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        guard let editor = firstEditor(in: host) else {
            XCTFail("no text editor in composer hierarchy")
            window.orderOut(nil)
            return -1
        }
        let width = editor.frame.width
        window.orderOut(nil)
        return width
    }

    func test_typingFirstCharacter_keepsInputFieldWidth() {
        let empty = editorWidth(input: "", roomID: "!accessory-empty:s")
        let typed = editorWidth(input: "hi", roomID: "!accessory-typed:s")
        XCTAssertEqual(
            empty, typed, accuracy: 0.5,
            "the input field must not change width when the mic swaps to the send button (empty: \(empty), typed: \(typed))"
        )
    }

    private func firstEditor(in view: NSView) -> NSView? {
        if view is NSTextField || view is NSTextView { return view }
        for sub in view.subviews {
            if let found = firstEditor(in: sub) { return found }
        }
        return nil
    }
}
#endif
