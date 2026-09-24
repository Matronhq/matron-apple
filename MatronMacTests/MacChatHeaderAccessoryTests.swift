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
    /// The Coordinator panel's width while it is open.
    @Published var trailingInset: CGFloat = 0
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
                List { Text("sidebar") }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("New") {}
                        }
                    }
            } detail: {
                MacChatHeaderHost(trailingInset: model.trailingInset) { detail }
            }
        } else {
            Text("another tab")
        }
    }

    @ViewBuilder private var detail: some View {
        if let roomID = model.roomID {
            if headerAsToolbar {
                Color.clear
                    .toolbar { ToolbarItem(placement: .principal) { Text("Chat \(roomID)") } }
                    .id(roomID)
            } else {
                Color.clear
                    .preference(key: MacChatToolbarPreference.self, value: makeProps(roomID: roomID, strip: strip))
                    .id(roomID)
            }
        } else {
            Text("no chat")
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

    /// Spec §3b: with the Coordinator panel open the header keeps its
    /// capsules over the detail, clear of the panel below the title bar.
    func test_trailingInset_keepsTheCapsulesOffThePanel() async throws {
        let (window, model) = makeWindow()
        defer { window.close() }
        model.trailingInset = 380
        let accessory = try await settledAccessory(in: window, roomID: "room-a")
        let reported = await Self.poll(seconds: 10) { accessory.hitRegions.capsules.count >= 2 }
        XCTAssertTrue(reported)
        let rightmost = accessory.hitRegions.capsules.map(\.maxX).max() ?? .infinity
        XCTAssertLessThanOrEqual(rightmost, accessory.view.frame.width - 380 + 1)
    }

    // MARK: - Harness

    private func makeWindow(headerAsToolbar: Bool = false) -> (NSWindow, HarnessModel) {
        let model = HarnessModel()
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
