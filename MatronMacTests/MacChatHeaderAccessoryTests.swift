#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

private final class FakeChatForHeader: ChatService, @unchecked Sendable {
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        AsyncStream { $0.finish() }
    }
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

private final class HarnessModel: ObservableObject {
    /// `nil` = no chat column on screen (empty state, pane takeover).
    @Published var roomID: String? = "room-a"
    /// `false` = another tab replaced the whole split view.
    @Published var showsSplitView = true
    /// The Tasks pane's shape beside the chat column: a `NavigationStack`
    /// under the same header, with `panePath` pushed onto it.
    var showsPane = false
    @Published var panePath: [String] = []
    /// `false` leaves the stack's system Back item in place — the control
    /// for the clipping test.
    var paneHidesBackButton = true
    /// The app's own sidebar toolbar: no system sidebar toggle, a flexible
    /// spacer, then "New" — `MacChatListView.splitView`.
    var sidebarLikeTheApp = false
}

private let harnessPublisher = UUID()

@MainActor
private func makeProps(roomID: String, strip: SubChatStripViewModel, publisher: UUID = harnessPublisher) -> MacChatToolbarProps {
    MacChatToolbarProps(
        roomID: roomID, publisher: publisher, title: "Chat \(roomID)", boxName: nil, styledTitle: nil,
        accessibilityTitle: nil, status: nil, stripViewModel: strip, missionID: nil,
        needsYouCount: 0, itemsAvailable: true,
        actions: .init(onOpenSubChat: { _ in }, onCompact: {}, onOpenMission: { _ in },
                       showMediaBrowser: .constant(false), showItemsPane: .constant(false)))
}

/// App-shaped on purpose: a `NavigationSplitView` whose sidebar owns a real
/// toolbar item, and a per-room `.id` subtree in the detail. A bare hosting
/// controller with a single toolbar source behaves differently enough that a
/// result from one says nothing about the app (2026-09-17, PR #224).
private struct AppShapedHarness: View {
    @ObservedObject var model: HarnessModel
    let strip: SubChatStripViewModel
    /// The shape this replaced: the header as a `.toolbar` inside the room.
    var headerAsToolbar = false

    var body: some View {
        if model.showsSplitView {
            NavigationSplitView {
                sidebar
                    // Wide enough for its own toolbar item: narrower, the
                    // sidebar's "New" is what AppKit clips, and the » tests
                    // below read that as the detail section's.
                    .navigationSplitViewColumnWidth(min: 300, ideal: 300, max: 300)
            } detail: {
                MacChatHeaderHost { detail }
            }
        } else {
            Text("another tab")
        }
    }

    @ViewBuilder private var sidebar: some View {
        if model.sidebarLikeTheApp {
            List { Text("sidebar") }
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    #if compiler(>=6.2)
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible, placement: .primaryAction)
                    }
                    #endif
                    ToolbarItem(placement: .primaryAction) {
                        Button { } label: { Image(systemName: "square.and.pencil") }
                    }
                }
        } else {
            List { Text("sidebar") }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New") {}
                    }
                }
        }
    }

    @ViewBuilder private var detail: some View {
        if let roomID = model.roomID {
            // The app's shape when the Tasks pane is open: chat column and
            // pane side by side in an `HSplitView` (NSSplitView-backed, so
            // each side has its own hosting view) — `MacChatView.body`.
            HSplitView {
                Group {
                    if headerAsToolbar {
                        Color.clear
                            .toolbar { ToolbarItem(placement: .principal) { Text("Chat \(roomID)") } }
                            .id(roomID)
                    } else {
                        Color.clear
                            .preference(key: MacChatToolbarPreference.self, value: makeProps(roomID: roomID, strip: strip))
                            .id(roomID)
                    }
                }
                .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                if model.showsPane {
                    paneStack
                        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            Text("no chat")
        }
    }

    private var paneStack: some View {
        NavigationStack(path: $model.panePath) {
            Text("list").frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationDestination(for: String.self) { id in
                    let page = Text("item \(id)").frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.paneHidesBackButton {
                        page.modifier(MacItemsPaneStackDestination())
                    } else {
                        page
                    }
                }
        }
    }
}

/// Counts NSToolbar item insertions and removals — the churn the accessory
/// exists to avoid.
private final class ToolbarChurnProbe {
    private(set) var adds = 0
    private(set) var removes = 0
    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSToolbar.willAddItemNotification, object: nil, queue: nil) { [weak self] _ in
            self?.adds += 1
        })
        tokens.append(center.addObserver(forName: NSToolbar.didRemoveItemNotification, object: nil, queue: nil) { [weak self] _ in
            self?.removes += 1
        })
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

@MainActor
final class MacChatHeaderAccessoryTests: XCTestCase {

    func test_propsEquality_coversWhatIsDrawn_andTheRoom_notTheActions() {
        let strip = SubChatStripViewModel(chat: FakeChatForHeader(), parentConvoID: "p1")
        XCTAssertEqual(makeProps(roomID: "a", strip: strip), makeProps(roomID: "a", strip: strip),
                       "fresh closures alone must not read as a change, or every body pass republishes")
        XCTAssertNotEqual(makeProps(roomID: "a", strip: strip), makeProps(roomID: "b", strip: strip),
                          "a switch must republish so the header stops acting on the room that left")
        let otherStrip = SubChatStripViewModel(chat: FakeChatForHeader(), parentConvoID: "p2")
        XCTAssertNotEqual(makeProps(roomID: "a", strip: strip), makeProps(roomID: "a", strip: otherStrip))
        XCTAssertNotEqual(makeProps(roomID: "a", strip: strip), makeProps(roomID: "a", strip: strip, publisher: UUID()),
                          "the same room remounted is a new publisher: its bindings replace the dead instance's")
    }

    func test_preferenceReduce_keepsTheFirstPublisher() {
        let strip = SubChatStripViewModel(chat: FakeChatForHeader(), parentConvoID: "p1")
        var value: MacChatToolbarProps? = nil
        MacChatToolbarPreference.reduce(value: &value) { makeProps(roomID: "a", strip: strip) }
        MacChatToolbarPreference.reduce(value: &value) { makeProps(roomID: "b", strip: strip) }
        XCTAssertEqual(value?.roomID, "a")
    }

    // MARK: - Title placement

    func test_titleSpan_centresTheTitle_whenItFits() {
        let span = MacChatHeaderLayout.titleSpan(bounds: 0...1000, leading: 120, trailing: 200, ideal: 300, gap: 10)
        XCTAssertEqual(span.lowerBound, 350, accuracy: 0.01)
        XCTAssertEqual(span.upperBound, 650, accuracy: 0.01)
    }

    func test_titleSpan_slidesOffCentre_ratherThanUnderTheTrailingGroup() {
        let span = MacChatHeaderLayout.titleSpan(bounds: 0...1000, leading: 0, trailing: 400, ideal: 300, gap: 10)
        XCTAssertEqual(span.upperBound, 590, accuracy: 0.01, "stops a gap short of the trailing group")
        XCTAssertEqual(span.upperBound - span.lowerBound, 300, accuracy: 0.01, "and keeps its full width")
    }

    func test_titleSpan_shrinksToTheGap_whenThereIsNoRoom() {
        let span = MacChatHeaderLayout.titleSpan(bounds: 0...600, leading: 200, trailing: 250, ideal: 300, gap: 10)
        XCTAssertEqual(span.lowerBound, 210, accuracy: 0.01)
        XCTAssertEqual(span.upperBound, 340, accuracy: 0.01)
        let none = MacChatHeaderLayout.titleSpan(bounds: 0...300, leading: 200, trailing: 250, ideal: 300, gap: 10)
        XCTAssertEqual(none.upperBound - none.lowerBound, 0, accuracy: 0.01, "never a negative width")
    }

    // MARK: - The accessory in an app-shaped window

    func test_chatColumn_installsOneAccessory_showingItsProps() async throws {
        let (window, _) = makeWindow()
        defer { window.close() }
        let accessory = try await settledAccessory(in: window, roomID: "room-a")
        XCTAssertEqual(window.titlebarAccessoryViewControllers.filter { $0 is MacChatHeaderAccessory }.count, 1)
        XCTAssertEqual(accessory.model.props?.title, "Chat room-a")
        XCTAssertFalse(accessory.isHidden)
        XCTAssertEqual(accessory.layoutAttribute, .right)
    }

    /// The point of the whole arrangement: a room switch updates the header
    /// without touching the window's NSToolbar.
    func test_roomSwitch_updatesTheHeader_withoutToolbarChurn() async throws {
        let (window, model) = makeWindow()
        defer { window.close() }
        let accessory = try await settledAccessory(in: window, roomID: "room-a")

        let probe = ToolbarChurnProbe()
        model.roomID = "room-b"
        let switched = await Self.poll(seconds: 10) { accessory.model.props?.roomID == "room-b" }
        XCTAssertTrue(switched, "the header must follow the room")
        await Self.spin(seconds: 0.5)

        XCTAssertTrue(MacChatHeaderAccessory.existing(in: window) === accessory, "the accessory is never replaced")
        XCTAssertEqual(window.titlebarAccessoryViewControllers.filter { $0 is MacChatHeaderAccessory }.count, 1)
        XCTAssertEqual(probe.adds, 0, "a room switch must not add NSToolbar items")
        XCTAssertEqual(probe.removes, 0, "a room switch must not remove NSToolbar items")
    }

    /// Control — proves the probe above can see churn at all, and records
    /// what the header cost as a `.toolbar`.
    func test_roomSwitch_churnsTheToolbar_whenTheHeaderIsAToolbar() async throws {
        let (window, model) = makeWindow(headerAsToolbar: true)
        defer { window.close() }
        _ = await Self.poll(seconds: 10) { (window.toolbar?.items.count ?? 0) >= 2 }
        await Self.spin(seconds: 0.5)
        // macOS 15 does not bridge a state-driven toolbar in a bare hosting
        // window until its next change; without items there is nothing to churn.
        try XCTSkipIf((window.toolbar?.items.count ?? 0) < 2, "this OS did not bridge the harness toolbar")

        let probe = ToolbarChurnProbe()
        model.roomID = "room-b"
        await Self.spin(seconds: 1)
        XCTAssertGreaterThan(probe.adds + probe.removes, 0, "a `.toolbar` inside the room identity is rebuilt on every switch")
    }

    func test_noChatColumn_emptiesTheHeader() async throws {
        let (window, model) = makeWindow()
        defer { window.close() }
        let accessory = try await settledAccessory(in: window, roomID: "room-a")

        model.roomID = nil
        let cleared = await Self.poll(seconds: 10) { accessory.model.props == nil }
        XCTAssertTrue(cleared, "with no chat column mounted the header must not keep the old chat's title")

        model.roomID = "room-b"
        let back = await Self.poll(seconds: 10) { accessory.model.props?.roomID == "room-b" }
        XCTAssertTrue(back)
    }

    func test_anotherTab_hidesTheAccessory_andComingBackRestoresIt() async throws {
        let (window, model) = makeWindow()
        defer { window.close() }
        let accessory = try await settledAccessory(in: window, roomID: "room-a")

        model.showsSplitView = false
        let hidden = await Self.poll(seconds: 10) { accessory.isHidden }
        XCTAssertTrue(hidden, "a tab without a chat column must not show a chat header")
        XCTAssertNil(accessory.model.props)

        model.showsSplitView = true
        let back = await Self.poll(seconds: 10) { !accessory.isHidden && accessory.model.props?.roomID == "room-a" }
        XCTAssertTrue(back, "returning to the conversations tab brings the header back")
        XCTAssertTrue(MacChatHeaderAccessory.existing(in: window) === accessory)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.filter { $0 is MacChatHeaderAccessory }.count, 1)
    }

    /// Most of the window's title bar is this header's blank space; it has to
    /// keep dragging the window, so only the capsules take clicks.
    func test_clicksBetweenCapsules_fallThroughToTheTitleBar() async throws {
        let (window, _) = makeWindow()
        defer { window.close() }
        let accessory = try await settledAccessory(in: window, roomID: "room-a")
        let hosting = try XCTUnwrap(accessory.hostingView)
        let reported = await Self.poll(seconds: 10) { accessory.hitRegions.capsules.count >= 2 }
        XCTAssertTrue(reported, "the title and the buttons capsule must report their frames")

        let title = try XCTUnwrap(accessory.hitRegions.capsules.min { abs($0.midX - hosting.bounds.midX) < abs($1.midX - hosting.bounds.midX) })
        func hit(_ x: CGFloat) -> NSView? {
            let y = hosting.isFlipped ? title.midY : hosting.bounds.height - title.midY
            return hosting.hitTest(hosting.convert(NSPoint(x: x, y: y), to: hosting.superview))
        }
        XCTAssertNotNil(hit(title.midX), "the title capsule takes clicks")
        XCTAssertNil(hit(title.minX - 20), "the space beside it belongs to the title bar")
    }

    func test_accessoryWidth_followsTheChatColumn() async throws {
        let (window, _) = makeWindow()
        defer { window.close() }
        let accessory = try await settledAccessory(in: window, roomID: "room-a")
        let before = accessory.view.frame.width
        XCTAssertGreaterThan(before, 0)
        XCTAssertLessThan(before, window.frame.width, "the header spans the chat column, not the sidebar")

        window.setContentSize(NSSize(width: 1300, height: 500))
        let grew = await Self.poll(seconds: 10) { accessory.view.frame.width > before + 100 }
        XCTAssertTrue(grew, "widening the window widens the header (was \(before), now \(accessory.view.frame.width))")
    }

    // MARK: - Toolbar items under the header

    /// Under the accessory the detail section of the window's NSToolbar has
    /// no room, so nothing mounted beneath the header may add an item there.
    /// The Tasks pane's `NavigationStack` was the one thing that did: its
    /// automatic Back item was clipped into AppKit's `»` overflow menu (Dan,
    /// 2026-09-22). The pane draws its own Back instead.
    func test_paneStackPush_underTheHeader_addsNoToolbarItem() async throws {
        let (window, model) = makeWindow(showsPane: true)
        defer { window.close() }
        _ = try await settledAccessory(in: window, roomID: "room-a")
        XCTAssertGreaterThanOrEqual(window.toolbar?.items.count ?? 0, 2, "the harness toolbar must be bridged for this to mean anything")

        model.panePath = ["item-1"]
        await Self.spin(seconds: 1.5)
        XCTAssertFalse(Self.hasStackBackItem(window), "the pane draws its own Back; the stack must not add one to the toolbar")
        XCTAssertTrue(Self.clippedItemsIndicators(in: window).isEmpty, "nothing may be clipped into a » menu under the header — \(Self.toolbarDiagnostics(window))")
        // SwiftUI lifts the header host's platform view out of the window on
        // the push without dismantling it; the header must not read that as
        // the chat column leaving.
        let accessory = try XCTUnwrap(MacChatHeaderAccessory.existing(in: window))
        XCTAssertFalse(accessory.isHidden, "the header stays up while an item is open in the pane")
        XCTAssertEqual(accessory.model.props?.roomID, "room-a")
    }

    /// With the app's own sidebar toolbar, mounting the header — pane closed,
    /// then open at its list — must clip nothing either.
    func test_header_withTheAppsSidebarToolbar_clipsNothing() async throws {
        let (window, model) = makeWindow(sidebarLikeTheApp: true)
        defer { window.close() }
        _ = try await settledAccessory(in: window, roomID: "room-a")
        XCTAssertTrue(Self.clippedItemsIndicators(in: window).isEmpty, "pane closed — \(Self.toolbarDiagnostics(window))")

        model.showsPane = true
        model.roomID = "room-b"
        _ = await Self.poll(seconds: 10) { MacChatHeaderAccessory.existing(in: window)?.model.props?.roomID == "room-b" }
        await Self.spin(seconds: 1.5)
        XCTAssertTrue(Self.clippedItemsIndicators(in: window).isEmpty, "pane open at its list — \(Self.toolbarDiagnostics(window))")
    }

    /// Control — the clipping the test above guards against, with the
    /// stack's system Back item left in place.
    func test_paneStackPush_withTheSystemBackItem_isClippedIntoTheOverflowMenu() async throws {
        let (window, model) = makeWindow(showsPane: true, paneHidesBackButton: false)
        defer { window.close() }
        _ = try await settledAccessory(in: window, roomID: "room-a")

        model.panePath = ["item-1"]
        let bridged = await Self.poll(seconds: 5) { Self.hasStackBackItem(window) }
        try XCTSkipIf(!bridged, "this OS did not bridge the harness back button")
        let clipped = await Self.poll(seconds: 5) { !Self.clippedItemsIndicators(in: window).isEmpty }
        XCTAssertTrue(clipped, "with the accessory spanning the detail column the Back item has nowhere to go but the » menu")
    }

    private static func toolbarDiagnostics(_ window: NSWindow) -> String {
        let items = window.toolbar?.items.map { "\($0.itemIdentifier.rawValue):vis=\($0.isVisible)" } ?? []
        let indicators = clippedItemsIndicators(in: window).map {
            "\(type(of: $0))@\($0.frame) hidden=\($0.isHidden) alpha=\($0.alphaValue) super=\($0.superview.map { String(describing: type(of: $0)) } ?? "nil")"
        }
        let accessory = MacChatHeaderAccessory.existing(in: window).map { "w=\($0.view.frame.width) hidden=\($0.isHidden)" } ?? "none"
        return "items=\(items) indicators=\(indicators) accessory=\(accessory) window=\(window.frame.width)"
    }

    private static func hasStackBackItem(_ window: NSWindow) -> Bool {
        window.toolbar?.items.contains { $0.itemIdentifier.rawValue.hasSuffix("navigationStack.back") } ?? false
    }

    /// AppKit's `»` button — `NSToolbarClippedItemsIndicator` and its viewer
    /// — anywhere in the window's theme frame, after a layout pass.
    private static func clippedItemsIndicators(in window: NSWindow) -> [NSView] {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let root = window.contentView?.superview else { return [] }
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if String(describing: type(of: view)).contains("ClippedItemsIndicator") { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    // MARK: - Harness

    private func makeWindow(headerAsToolbar: Bool = false, showsPane: Bool = false,
                            paneHidesBackButton: Bool = true, sidebarLikeTheApp: Bool = false) -> (NSWindow, HarnessModel) {
        let model = HarnessModel()
        model.showsPane = showsPane
        model.paneHidesBackButton = paneHidesBackButton
        model.sidebarLikeTheApp = sidebarLikeTheApp
        let strip = SubChatStripViewModel(chat: FakeChatForHeader(), parentConvoID: "p1")
        let host = NSHostingController(rootView: AppShapedHarness(model: model, strip: strip, headerAsToolbar: headerAsToolbar))
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 900, height: 500))
        window.orderFront(nil)
        return (window, model)
    }

    private func settledAccessory(in window: NSWindow, roomID: String) async throws -> MacChatHeaderAccessory {
        _ = await Self.poll(seconds: 10) { MacChatHeaderAccessory.existing(in: window)?.model.props?.roomID == roomID }
        let accessory = try XCTUnwrap(MacChatHeaderAccessory.existing(in: window), "the chat column must install the header accessory")
        XCTAssertEqual(accessory.model.props?.roomID, roomID)
        await Self.spin(seconds: 0.5)
        return accessory
    }

    private static func poll(seconds: TimeInterval, until done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return done()
    }

    private static func spin(seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
#endif
