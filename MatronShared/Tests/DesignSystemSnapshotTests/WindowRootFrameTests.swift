#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import MatronDesignSystem

/// The window root's size probes must not reach its content: on the Mac
/// each one measured the whole split-view tree.
@MainActor
final class WindowRootFrameTests: XCTestCase {
    /// Counts the proposals it is asked about that are not a real size:
    /// zero, unspecified or infinite on either axis.
    final class ProbeLog { var probes = 0; var layouts = 0 }

    struct ProbeLayout: Layout {
        let log: ProbeLog
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let w = proposal.width, h = proposal.height
            let isProbe = w == nil || h == nil || w == 0 || h == 0 || w == .infinity || h == .infinity
            if isProbe { log.probes += 1 }
            return CGSize(width: 300, height: 200)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            log.layouts += 1
        }
    }

    private func host(_ view: some View) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        return hosting
    }

    func testTheRootFrameAnswersSizeProbesWithoutTheContent() {
        let log = ProbeLog()
        let hosting = host(ProbeLayout(log: log) { Color.clear }
            .windowRootFrame(minSize: CGSize(width: 800, height: 600), idealSize: CGSize(width: 1280, height: 860)))
        hosting.layoutSubtreeIfNeeded()
        let before = log.probes

        XCTAssertEqual(hosting.fittingSize, CGSize(width: 1280, height: 860))
        _ = hosting.intrinsicContentSize
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()

        XCTAssertEqual(log.probes, before, "a size probe reached the content")
        XCTAssertGreaterThan(log.layouts, 0, "the content still lays out")
    }

    /// The control: a minimums-only root frame, as before, sends the probes
    /// on to the content.
    func testAMinimumsOnlyFrameMeasuresTheContent() {
        let log = ProbeLog()
        let hosting = host(ProbeLayout(log: log) { Color.clear }.frame(minWidth: 800, minHeight: 600))
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.fittingSize
        XCTAssertGreaterThan(log.probes, 0)
    }
}
#endif
