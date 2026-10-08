#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac

/// Pins the inset on the chat-column attention banners by rendering them
/// and sampling pixels — the bug was purely "the colour reaches the
/// leading edge", so the assertion is literally that it doesn't.
///
/// Rendering rather than reading the modifier's constants: a padding value
/// that never makes it to the screen (wrong modifier order, a later
/// `frame(maxWidth:)`) would still satisfy a constant check.
final class MacChatTopBannerTests: XCTestCase {
    private let size = NSSize(width: 400, height: 60)

    /// A full-bleed red strip — the shape both real banners have before
    /// the modifier runs.
    private var strip: some View {
        Color.red
            .frame(maxWidth: .infinity)
            .frame(height: 30)
    }

    private func render(_ view: some View) throws -> NSBitmapImageRep {
        let host = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color.white)
        )
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// True when the sampled *point* is the banner's red rather than the
    /// white ground. Deliberately loose on colour — colour management
    /// shifts the exact components, but red-vs-white is unambiguous.
    ///
    /// Takes points and converts: the cached rep is backing-scale sized
    /// (1600×240 for this 400×60 view on a Retina display) and
    /// `colorAt(x:y:)` indexes PIXELS, so sampling "width − 2" directly
    /// lands mid-view instead of at the trailing edge.
    private func isBanner(_ rep: NSBitmapImageRep, xPt: Double, yPt: Double) throws -> Bool {
        let scaleX = Double(rep.pixelsWide) / size.width
        let scaleY = Double(rep.pixelsHigh) / size.height
        let x = min(Int(xPt * scaleX), rep.pixelsWide - 1)
        let y = min(Int(yPt * scaleY), rep.pixelsHigh - 1)
        let colour = try XCTUnwrap(rep.colorAt(x: x, y: y)).usingColorSpace(.deviceRGB)
        let c = try XCTUnwrap(colour)
        return c.redComponent > 0.5 && c.greenComponent < 0.5 && c.blueComponent < 0.5
    }

    /// The regression: without the modifier the strip paints the full
    /// width, so its colour reaches the leading edge — where the macOS 26
    /// sidebar divider is, which is what made it look like it continued
    /// behind the sidebar.
    func test_withoutTheModifier_theBannerReachesTheLeadingEdge() throws {
        let rep = try render(strip)

        XCTAssertTrue(try isBanner(rep, xPt: 1, yPt: 15), "baseline: full-bleed strip paints the edge")
    }

    func test_insetBanner_leavesTheLeadingAndTrailingEdgesClear() throws {
        let rep = try render(strip.chatTopBanner())

        XCTAssertFalse(try isBanner(rep, xPt: 1, yPt: 20), "leading edge must stay clear of the sidebar divider")
        XCTAssertFalse(
            try isBanner(rep, xPt: size.width - 1, yPt: 20),
            "trailing edge clear too, so the inset reads as symmetric"
        )
    }

    func test_insetBanner_stillPaintsAcrossTheMiddle() throws {
        let rep = try render(strip.chatTopBanner())

        XCTAssertTrue(
            try isBanner(rep, xPt: size.width / 2, yPt: 20),
            "the banner is still a full-width strip, just inset — not shrunk to its text"
        )
    }

    /// The other half of "welded to the window frame": it sat hard against
    /// the toolbar.
    func test_insetBanner_leavesSpaceAboveIt() throws {
        let rep = try render(strip.chatTopBanner())

        XCTAssertFalse(
            try isBanner(rep, xPt: size.width / 2, yPt: 1),
            "top spacing lifts the banner off the toolbar"
        )
    }
}
#endif
