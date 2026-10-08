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
    /// An item open with no chat column (the Decisions page).
    @Published var itemNum: Int? = nil
}

private let harnessPublisher = UUID()
private final class ItemPublisher {}
private let itemPublisher = ItemPublisher()

private func makeItemHeader(num: Int, isOpen: Bool = true, busy: Bool = false,
                            publisher: AnyObject = itemPublisher) -> MacItemHeaderProps {
    MacItemHeaderProps(itemID: "it_\(num)", publisher: ObjectIdentifier(publisher),
                       isOpen: isOpen, resolutions: [.answered, .cancelled], isBusy: busy,
                       canReopen: true, onClose: { _ in }, onReopen: {})
}

@MainActor
private func makeProps(roomID: String, strip: SubChatStripViewModel, publisher: UUID = harnessPublisher) -> MacChatToolbarProps {
    MacChatToolbarProps(
        roomID: roomID, publisher: publisher, title: "Chat \(roomID)", boxName: nil, styledTitle: nil,
        accessibilityTitle: nil, status: nil, stripViewModel: strip, missions: ConversationMissions(), projectTitles: [:],
        needsYouCount: 0, itemsAvailable: true,
        actions: .init(onOpenSubChat: { _ in }, onCompact: {}, onOpenMission: { _ in }, onOpenProject: { _ in },
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
                MacChatHeaderHost { detail }
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
        } else if let num = model.itemNum {
            Color.clear.preference(key: MacItemHeaderPreference.self, value: makeItemHeader(num: num))
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

    func test_itemHeaderEquality_coversWhatIsDrawn_notTheActions() {
        XCTAssertEqual(makeItemHeader(num: 1), makeItemHeader(num: 1),
                       "fresh closures alone must not read as a change")
        XCTAssertNotEqual(makeItemHeader(num: 1), makeItemHeader(num: 2))
        XCTAssertNotEqual(makeItemHeader(num: 1), makeItemHeader(num: 1, isOpen: false), "closed offers Reopen")
        XCTAssertNotEqual(makeItemHeader(num: 1), makeItemHeader(num: 1, busy: true), "the menu disables while busy")
        XCTAssertNotEqual(makeItemHeader(num: 1), makeItemHeader(num: 1, publisher: ItemPublisher()),
                          "a rebuilt view model must replace the menu's actions")
    }

    func test_backing_sitsBehindAChatHeader_butNotBehindAnOpenItem() {
        let strip = SubChatStripViewModel(chat: FakeChatForHeader(), parentConvoID: "p1")
        let model = MacChatHeaderModel()
        XCTAssertFalse(MacChatHeaderBar.drawsBacking(model), "nothing to back")
        model.props = makeProps(roomID: "a", strip: strip)
        XCTAssertTrue(MacChatHeaderBar.drawsBacking(model), "a transcript scrolls under the clear bar")
        model.props = nil
        model.item = makeItemHeader(num: 1)
        XCTAssertFalse(MacChatHeaderBar.drawsBacking(model), "the item runs up to the top: no band over it")
    }

    func test_install_makesTheTitleBarClear() async throws {
        let (window, _) = makeWindow()
        defer { window.close() }
        _ = try await settledAccessory(in: window, roomID: "room-a")
        XCTAssertTrue(window.titlebarAppearsTransparent)
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

    // MARK: - Title first, then the trailing group

    /// 1000 pt bar, 150 pt leading group, 10 pt gaps; the trailing group
    /// runs 300 pt (chip number-only) to 450 pt (chip at its cap).
    private func trailing(title: CGFloat) -> CGFloat {
        MacChatHeaderLayout.trailingWidth(total: 1000, leading: 150, title: title, trailingMin: 300,
                                          trailingIdeal: 450, gap: 10)
    }

    func test_trailingWidth_narrow_keepsTheChipAtItsMinimum_andTheTitleTakesTheRest() {
        let trailing = trailing(title: 700)
        XCTAssertEqual(trailing, 300, accuracy: 0.01)
        let span = MacChatHeaderLayout.titleSpan(bounds: 0...1000, leading: 150, trailing: trailing, ideal: 700,
                                                 gap: 10)
        XCTAssertEqual(span.upperBound - span.lowerBound, 530, accuracy: 0.01, "everything between the groups")
    }

    func test_trailingWidth_medium_showsTheWholeTitle_andTheChipBetweenItsMinimumAndCap() {
        let trailing = trailing(title: 460)
        XCTAssertEqual(trailing, 370, accuracy: 0.01)
        let span = MacChatHeaderLayout.titleSpan(bounds: 0...1000, leading: 150, trailing: trailing, ideal: 460,
                                                 gap: 10)
        XCTAssertEqual(span.upperBound - span.lowerBound, 460, accuracy: 0.01)
    }

    func test_trailingWidth_wide_showsTheWholeTitle_andCapsTheChip() {
        let trailing = trailing(title: 200)
        XCTAssertEqual(trailing, 450, accuracy: 0.01)
        let span = MacChatHeaderLayout.titleSpan(bounds: 0...1000, leading: 150, trailing: trailing, ideal: 200,
                                                 gap: 10)
        XCTAssertEqual(span.upperBound - span.lowerBound, 200, accuracy: 0.01)
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

    /// The Decisions page: no chat column, an item open — the strip shows
    /// the item instead of staying blank, and lets it go when it closes.
    func test_openItem_withNoChatColumn_fillsTheHeader_andClearsWhenItLeaves() async throws {
        let (window, model) = makeWindow()
        defer { window.close() }
        let accessory = try await settledAccessory(in: window, roomID: "room-a")

        model.roomID = nil
        model.itemNum = 42
        let shown = await Self.poll(seconds: 10) { accessory.model.props == nil && accessory.model.item?.itemID == "it_42" }
        XCTAssertTrue(shown, "the open item must reach the header")
        XCTAssertFalse(accessory.isHidden)

        model.itemNum = nil
        let cleared = await Self.poll(seconds: 10) { accessory.model.item == nil }
        XCTAssertTrue(cleared, "with no item open the header must not keep the old item's title")
    }

    /// The item's ⋯ circle leaves its glass shadow room above the strip's
    /// bottom edge, where the title bar clips it (a 38 pt
    /// capsule left 7 pt and the shadow ended in a hard line).
    func test_openItem_menuCircle_clearsTheStripBottom() async throws {
        let (window, model) = makeWindow()
        defer { window.close() }
        let accessory = try await settledAccessory(in: window, roomID: "room-a")

        model.roomID = nil
        model.itemNum = 42
        let drawn = await Self.poll(seconds: 10) {
            accessory.model.item != nil && accessory.hitRegions.capsules.count == 1
        }
        XCTAssertTrue(drawn, "the item's menu must draw one capsule")
        let circle = try XCTUnwrap(accessory.hitRegions.capsules.first)
        XCTAssertEqual(circle.width, MacItemHeaderBar.menuDiameter, accuracy: 0.5)
        XCTAssertEqual(circle.height, MacItemHeaderBar.menuDiameter, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(MacChatHeaderAccessory.height - circle.maxY, 10)
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
