#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

/// Local fake mirroring `FakeTimelineForChat` in `MacChatViewTests` — the
/// Mac test target is self-contained and doesn't pull the SPM test fakes.
private final class FakeTimelineForPalette: TimelineService, @unchecked Sendable {
    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}
}

/// Pins the slash palette's float-above placement by rendering the composer
/// and comparing pixels between palette-shown and palette-hidden states,
/// instead of against a stored baseline — differential assertions survive
/// the cross-macOS-version rendering drift that forces the snapshot tests
/// to skip on CI.
///
/// Regression under test (Dan, 2026-07-15): a custom `.alignmentGuide` set
/// INSIDE conditional content (`if showPalette { … }`) is dropped by
/// SwiftUI's `ConditionalContent`, so the palette top-aligned INTO the
/// composer — covering the input, clipped to the composer strip — instead
/// of floating up over the timeline.
@MainActor
final class MacComposerPaletteLayoutTests: XCTestCase {

    private static let width: CGFloat = 480
    private static let timelineHeight: CGFloat = 300

    /// Renders the chat-bottom fixture (red timeline stand-in above the
    /// composer, mirroring `MacChatView`'s VStack) to a bitmap. `input`
    /// controls `showPalette` ("/" opens the full command palette).
    private func render(input: String, roomID: String) -> NSBitmapImageRep {
        let vm = ComposerViewModel(
            roomID: roomID,
            timeline: FakeTimelineForPalette(),
            commands: BotCommandCatalog.claudeBridge
        )
        vm.input = input
        let fixture = VStack(spacing: 0) {
            Color.red.frame(height: Self.timelineHeight)
            Divider()
            MacComposerView(viewModel: vm)
        }
        .frame(width: Self.width)

        let host = NSHostingView(rootView: fixture)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        // Let the palette's shrink-to-fit `onGeometryChange` land before
        // caching — its measured height arrives a runloop turn after the
        // first layout pass.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fatalError("no bitmap rep for composer fixture")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    /// Pixel at view-space point (top-left origin — `NSHostingView` is
    /// flipped), scaled to the bitmap's backing resolution.
    private func pixel(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> NSColor? {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        return rep.colorAt(x: Int(x * scale), y: Int(y * scale))
    }

    func test_palette_floatsAboveComposer_withoutCoveringInput() {
        let shown = render(input: "/", roomID: "!palette-on:s")
        let hidden = render(input: "", roomID: "!palette-off:s")
        XCTAssertEqual(shown.size, hidden.size, "fixture height must not depend on the palette (it must overlay, not push layout)")

        // Both bitmaps share geometry: timeline 0..<300, then divider+composer.
        let midX = Self.width / 2

        // 1. The palette floats UP over the timeline: the region just above
        //    the composer is covered when the palette shows.
        let overTimelineShown = pixel(shown, x: midX, y: Self.timelineHeight - 60)
        let overTimelineHidden = pixel(hidden, x: midX, y: Self.timelineHeight - 60)
        XCTAssertNotEqual(
            overTimelineShown, overTimelineHidden,
            "palette must draw over the timeline just above the composer"
        )

        // 2. …but not all the way up: above the palette's 220pt max height
        //    the timeline stays untouched.
        XCTAssertEqual(
            pixel(shown, x: midX, y: 20), pixel(hidden, x: midX, y: 20),
            "palette must not extend to the top of the timeline"
        )

        // 3. The composer strip is NOT covered — the panel grows upward from
        //    the input, never over it. Sample right of the typed text /
        //    placeholder (which legitimately differ between the two renders)
        //    and left of the trailing send/mic button.
        let composerMidY = Self.timelineHeight + (shown.size.height - Self.timelineHeight) / 2
        XCTAssertEqual(
            pixel(shown, x: Self.width - 100, y: composerMidY),
            pixel(hidden, x: Self.width - 100, y: composerMidY),
            "palette must not cover the input field"
        )
    }
}
#endif
