#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac

private final class Counter { var appears = 0; var width: CGFloat = 0 }

private struct DetailProbe: View {
    let counter: Counter
    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { counter.appears += 1; counter.width = geo.size.width }
                .onChange(of: geo.size.width) { _, width in counter.width = width }
        }
    }
}

private final class PanelModel: ObservableObject {
    @Published var isOpen = true
    @Published var width: Double = 380
}

private struct Harness: View {
    @ObservedObject var model: PanelModel
    let counter: Counter
    var body: some View {
        MacCoordinatorPanelContainer(isOpen: model.isOpen, width: $model.width) {
            DetailProbe(counter: counter)
        } panel: {
            Color.gray
        }
    }
}

@MainActor
final class MacCoordinatorPanelLayoutTests: XCTestCase {
    func test_clampKeepsTheSpecMinimum() {
        XCTAssertEqual(MacCoordinatorPanelLayout.clamp(100), 320)
        XCTAssertEqual(MacCoordinatorPanelLayout.clamp(380), 380)
        XCTAssertEqual(MacCoordinatorPanelLayout.clamp(5000), MacCoordinatorPanelLayout.maxWidth)
        XCTAssertEqual(MacCoordinatorPanelLayout.idealWidth, 380)
    }

    func test_modeSitsBesideUntilTheDetailWouldDropUnderItsMinimum() {
        XCTAssertEqual(MacCoordinatorPanelLayout.mode(isOpen: false, containerWidth: 1200, panelWidth: 380), .closed)
        XCTAssertEqual(MacCoordinatorPanelLayout.mode(isOpen: true, containerWidth: 800, panelWidth: 380), .beside)
        XCTAssertEqual(MacCoordinatorPanelLayout.mode(isOpen: true, containerWidth: 799, panelWidth: 380), .overlay)
    }

    func test_paddingAndInsetPerMode() {
        XCTAssertEqual(MacCoordinatorPanelLayout.detailTrailingPadding(mode: .beside, panelWidth: 380), 380)
        XCTAssertEqual(MacCoordinatorPanelLayout.detailTrailingPadding(mode: .overlay, panelWidth: 380), 0)
        XCTAssertEqual(MacCoordinatorPanelLayout.detailTrailingPadding(mode: .closed, panelWidth: 380), 0)
        XCTAssertEqual(MacCoordinatorPanelLayout.headerTrailingInset(isOpen: true, panelWidth: 380), 380)
        XCTAssertEqual(MacCoordinatorPanelLayout.headerTrailingInset(isOpen: false, panelWidth: 380), 0)
    }

    func test_dragOfTheLeadingEdgeResizes() {
        XCTAssertEqual(MacCoordinatorPanelLayout.resized(from: 380, translation: -50), 430, "dragging left widens")
        XCTAssertEqual(MacCoordinatorPanelLayout.resized(from: 380, translation: 200), 320, "never under the minimum")
    }

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    func test_besideThePanel_theDetailGetsTheRest_andOverlaysWhenNarrow() async {
        let counter = Counter()
        let window = mount(Harness(model: PanelModel(), counter: counter), width: 1000)
        await Self.settle(window)
        XCTAssertEqual(counter.width, 620, accuracy: 1)
        window.setContentSize(NSSize(width: 700, height: 400))
        await Self.settle(window)
        XCTAssertEqual(counter.width, 700, accuracy: 1, "under 420 pt of detail the panel overlays instead")
    }

    /// Review focus: toggling or resizing the panel must not remount the
    /// transcript underneath.
    func test_togglingThePanel_neverRemountsTheDetail() async {
        let counter = Counter()
        let model = PanelModel()
        let window = mount(Harness(model: model, counter: counter), width: 1000)
        await Self.settle(window)
        model.isOpen = false
        await Self.settle(window)
        model.isOpen = true
        model.width = 500
        await Self.settle(window)
        XCTAssertEqual(counter.appears, 1)
    }

    /// A real window: a windowless `NSHostingView` does not reliably run
    /// `onAppear`.
    private func mount<V: View>(_ view: V, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: width, height: 400))
        window.orderFront(nil)
        self.window = window
        return window
    }

    private static func settle(_ window: NSWindow) async {
        let end = Date().addingTimeInterval(0.4)
        while Date() < end {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
#endif
