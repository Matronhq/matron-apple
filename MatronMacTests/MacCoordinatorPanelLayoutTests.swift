#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac

private final class Counter { var appears = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

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

private struct PanelProbe: View {
    let counter: Counter
    var body: some View {
        GeometryReader { geo in
            Color.gray
                .onAppear { counter.width = geo.size.width; counter.height = geo.size.height }
                .onChange(of: geo.size) { _, size in counter.width = size.width; counter.height = size.height }
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
    var panelCounter = Counter()
    var body: some View {
        MacCoordinatorPanelContainer(isOpen: model.isOpen, width: $model.width) {
            DetailProbe(counter: counter)
        } panel: {
            PanelProbe(counter: panelCounter)
        }
    }
}

/// Counts writes to the stored width — each one re-evaluates the root
/// view that owns the `@SceneStorage`.
private final class WidthStore: ObservableObject {
    @Published var isOpen = true
    var width: Double = 380
    var writes = 0
}

private struct DragHarness: View {
    @ObservedObject var store: WidthStore
    let panelCounter: Counter
    var body: some View {
        MacCoordinatorPanelContainer(isOpen: store.isOpen, width: Binding(
            get: { store.width },
            set: { store.width = $0; store.writes += 1; store.objectWillChange.send() })) {
            Color.white
        } panel: {
            PanelProbe(counter: panelCounter)
        }
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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

    /// Controller ruling (Task 13 review): the header clears what is DRAWN —
    /// under an overlay the panel is clipped to the container, not its
    /// stored width.
    func test_drawnPanelWidth_isClippedToTheContainerUnderAnOverlay() {
        XCTAssertEqual(MacCoordinatorPanelLayout.drawnPanelWidth(mode: .closed, panelWidth: 380, containerWidth: 1000), 0)
        XCTAssertEqual(MacCoordinatorPanelLayout.drawnPanelWidth(mode: .beside, panelWidth: 380, containerWidth: 1000), 380)
        XCTAssertEqual(MacCoordinatorPanelLayout.drawnPanelWidth(mode: .overlay, panelWidth: 380, containerWidth: 700), 380)
        XCTAssertEqual(MacCoordinatorPanelLayout.drawnPanelWidth(mode: .overlay, panelWidth: 720, containerWidth: 600), 600)
        XCTAssertEqual(MacCoordinatorPanelLayout.drawnPanelWidth(mode: .overlay, panelWidth: 100, containerWidth: 600), 320,
                       "a stored width under the minimum still draws at the minimum")
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
        XCTAssertEqual(counter.appears, 1, "moving into overlay mode must not remount the detail")
    }

    /// Controller ruling (Task 13 review): the panel column fills the
    /// container's height, beside or overlaid, and sits at its trailing edge.
    func test_panelFillsTheHeight() async {
        let panel = Counter()
        let window = mount(Harness(model: PanelModel(), counter: Counter(), panelCounter: panel), width: 1000)
        await Self.settle(window)
        XCTAssertEqual(panel.height, 400, accuracy: 1)
        XCTAssertEqual(panel.width, 380, accuracy: 1)
        window.setContentSize(NSSize(width: 700, height: 500))
        await Self.settle(window)
        XCTAssertEqual(panel.height, 500, accuracy: 1, "overlaid, the panel still runs the full height")
    }

    /// Review focus: toggling or resizing the panel must not remount the
    /// transcript underneath.
    func test_togglingThePanel_neverRemountsTheDetail() async {
        let counter = Counter()
        let model = PanelModel()
        let window = mount(Harness(model: model, counter: counter), width: 1000)
        await Self.settle(window)
        XCTAssertEqual(counter.width, 620, accuracy: 1, "open beside")
        model.isOpen = false
        await Self.settle(window)
        XCTAssertEqual(counter.width, 1000, accuracy: 1, "closed")
        model.isOpen = true
        model.width = 500
        await Self.settle(window)
        XCTAssertEqual(counter.width, 500, accuracy: 1, "reopened wider")
        // Through overlay mode: narrow the window, then toggle there.
        window.setContentSize(NSSize(width: 700, height: 400))
        await Self.settle(window)
        XCTAssertEqual(counter.width, 700, accuracy: 1, "overlaid")
        model.isOpen = false
        await Self.settle(window)
        XCTAssertEqual(counter.width, 700, accuracy: 1, "closed from overlay")
        model.isOpen = true
        await Self.settle(window)
        XCTAssertEqual(counter.width, 700, accuracy: 1, "reopened as an overlay")
        window.setContentSize(NSSize(width: 1000, height: 400))
        await Self.settle(window)
        XCTAssertEqual(counter.width, 500, accuracy: 1, "back beside once there is room")
        XCTAssertEqual(counter.appears, 1)
    }

    /// Fix round 1 (ruling 4): a drag resizes the panel live but writes the
    /// stored (scene) width ONCE, on release — every write re-evaluates the
    /// window's root view.
    func test_drag_resizesLive_andCommitsTheWidthOnceOnRelease() async {
        let store = WidthStore()
        let panel = Counter()
        let window = mountForMouse(DragHarness(store: store, panelCounter: panel), width: 1000)
        await Self.settle(window)
        XCTAssertEqual(panel.width, 380, accuracy: 1)
        let edge: CGFloat = 1000 - 380
        await Self.mouse(.leftMouseDown, x: edge + 3, in: window)
        for step in 1...5 {
            await Self.mouse(.leftMouseDragged, x: edge + 3 - CGFloat(step) * 20, in: window)
        }
        XCTAssertEqual(panel.width, 480, accuracy: 2, "the panel follows the pointer while dragging")
        XCTAssertEqual(store.writes, 0, "no stored-width writes mid-drag")
        await Self.mouse(.leftMouseUp, x: edge + 3 - 100, in: window)
        await Self.settle(window)
        XCTAssertEqual(store.writes, 1, "one write on release")
        XCTAssertEqual(store.width, 480, accuracy: 2)
        XCTAssertEqual(panel.width, 480, accuracy: 2)
    }

    /// Fix round 1 (ruling 5): the handle's hit area sits mostly INSIDE the
    /// panel (about 2 pt outside, 7 pt inside), so it barely overlaps the
    /// detail's trailing edge.
    func test_handleHitArea_isBiasedIntoThePanel() async {
        XCTAssertEqual(MacCoordinatorPanelContainer<Color, Color>.handleOutside, 2)
        XCTAssertEqual(MacCoordinatorPanelContainer<Color, Color>.handleInside, 7)
        let store = WidthStore()
        let window = mountForMouse(DragHarness(store: store, panelCounter: Counter()), width: 1000)
        await Self.settle(window)
        let edge: CGFloat = 1000 - 380
        // 3 pt out over the detail: not the handle.
        await Self.mouse(.leftMouseDown, x: edge - 3, in: window)
        await Self.mouse(.leftMouseDragged, x: edge - 60, in: window)
        await Self.mouse(.leftMouseUp, x: edge - 60, in: window)
        await Self.settle(window)
        XCTAssertEqual(store.writes, 0, "a press 3 pt over the detail must not resize the panel")
        // 6 pt in: the handle.
        await Self.mouse(.leftMouseDown, x: edge + 6, in: window)
        await Self.mouse(.leftMouseDragged, x: edge - 40, in: window)
        await Self.mouse(.leftMouseUp, x: edge - 40, in: window)
        await Self.settle(window)
        XCTAssertEqual(store.writes, 1, "a press 6 pt inside the panel's edge grabs the handle")
    }

    private static func mouse(_ type: NSEvent.EventType, x: CGFloat, in window: NSWindow) async {
        let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 200), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        if let event { window.sendEvent(event) }
        let end = Date().addingTimeInterval(0.06)
        while Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
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

    /// Mouse tests: the test host never gets a key window, and a hosting
    /// view in a non-key window swallows the first click — this one takes it.
    private func mountForMouse<V: View>(_ view: V, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = FirstMouseHostingView(rootView: view)
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
