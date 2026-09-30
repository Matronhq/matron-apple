#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac
import MatronModels

/// The Mac mission page: width rules, the page model's lookups, the
/// remembered Overview | Board switcher, and a Board card click.
@MainActor
final class MacMissionPageTests: XCTestCase {
    private typealias F = MacMissionPageFixtures
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        // A throwaway suite, never the app's own defaults: the test host IS
        // the app, and its standard defaults are the user's.
        suiteName = "MacMissionPageTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Width

    func testContentIsCappedAndCentredWidth() {
        XCTAssertEqual(MacMissionPageLayout.contentWidth(detailWidth: 2_000), 1_300)
        XCTAssertEqual(MacMissionPageLayout.contentWidth(detailWidth: 1_000), 1_000 - 2 * MacMissionPageLayout.horizontalPadding)
        XCTAssertEqual(MacMissionPageLayout.contentWidth(detailWidth: 10), 0)
    }

    /// Two columns once the DETAIL column is ~900pt wide, one below.
    func testOverviewGoesToTwoColumnsAt900OfDetailWidth() {
        XCTAssertFalse(MacMissionPageLayout.usesTwoColumns(detailWidth: 899))
        XCTAssertTrue(MacMissionPageLayout.usesTwoColumns(detailWidth: 900))
        XCTAssertTrue(MacMissionPageLayout.usesTwoColumns(detailWidth: 1_440))
        XCTAssertFalse(MacMissionPageLayout.usesTwoColumns(detailWidth: 800))
    }

    // MARK: Model

    func testNeedsYouAndOtherOpenItemsSplitTheOpenItems() {
        let model = F.model()
        XCTAssertEqual(model.needsYouItems.map(\.num), [3801, 3802, 3803])
        XCTAssertEqual(model.otherOpenItems.map(\.num), [3804, 3805, 3806, 3807])
        XCTAssertEqual(model.needsYouCount, 3)
    }

    /// Once the local rows are read they are the count (they follow item
    /// markers live, the server's number does not); until then, the
    /// server's.
    func testTheNeedsYouPillFollowsTheLocalRowsOnceLoaded() {
        var model = F.model()
        model.mission = Mission(id: "ms_1", num: 1, title: "M", originConvoID: "c", needsYou: 5)
        XCTAssertEqual(model.needsYouCount, 3, "loaded rows win, even below the server's count")
        model.openItemsLoaded = false
        model.openItems = []
        XCTAssertEqual(model.needsYouCount, 5)
    }

    func testMilestoneAccessibilityLabelCarriesBodyAndAge() {
        let milestone = F.milestones[0]
        XCTAssertEqual(MacMilestoneRow.accessibilityLabel(for: milestone, now: F.now),
                       "Your input 9, Dan: tracker threads need parity with chat, "
                       + "Decided items, tables, queued drops, image paste, Shift+Return., 16m ago")
        XCTAssertEqual(MacMilestoneRow.accessibilityLabel(for: F.milestones[4], now: F.now),
                       "Your input 5, Dan: remove the ⌘0 side panel; redesign Missions as a live dashboard, 16h ago",
                       "no body, no empty part")
    }

    /// Bodies are parsed once per milestone, and re-parsed only when one
    /// changes.
    func testMilestoneBodiesAreParsedOnce() {
        let cache = MacMilestoneBodyCache()
        let first = cache.bodies(for: F.milestones)
        XCTAssertEqual(first.count, 4, "the body-less milestone has no entry")
        XCTAssertEqual(cache.bodies(for: F.milestones), first)
        var edited = F.milestones
        edited[0] = F.milestone(9, .userInput, "Dan: tracker threads need parity with chat", "Now **bold**.", 16 * F.minute)
        XCTAssertEqual(String(cache.bodies(for: edited)["ml_9"]!.characters), "Now bold.")
    }

    /// A session row's box first, then the mission detail's conversation
    /// box; unknown ⇒ nil (the card says "Agent").
    func testBoxNameAndConversationTitleLookups() {
        var model = F.model()
        model.conversations = [MissionConversation(id: "c-bare", title: "ab: Bare session", box: "dev-2", state: "waiting")]
        XCTAssertEqual(model.boxName("c-nav"), "dan-mac")
        XCTAssertEqual(model.boxName("c-mem"), "ang")
        XCTAssertEqual(model.boxName("c-bare"), "dev-2")
        XCTAssertNil(model.boxName("c-unknown"))
        XCTAssertEqual(model.conversationTitle("c-nav"), "Missions Navigation Refinement")
        XCTAssertNil(model.conversationTitle("c-unknown"))
    }

    // MARK: Switcher

    func testTheViewDefaultsToOverview() {
        XCTAssertNil(defaults.string(forKey: MacMissionPage.modeKey))
        let host = HostedView(MacMissionPageTopBar(backConvoID: nil, onBack: { _ in }, onShowDashboard: {},
                                                   store: defaults))
        defer { host.close() }
        XCTAssertEqual(try XCTUnwrap(host.segmentedControl()).selectedSegment, 0)
    }

    /// Choosing Board is remembered: it lands in the page's AppStorage key,
    /// and the next page (a fresh top bar and content) opens on Board.
    func testChoosingBoardIsRememberedForTheNextPage() throws {
        let first = HostedView(MacMissionPageTopBar(backConvoID: nil, onBack: { _ in }, onShowDashboard: {},
                                                    store: defaults))
        let control = try XCTUnwrap(first.segmentedControl())
        XCTAssertEqual(control.segmentCount, 2)
        XCTAssertEqual(control.label(forSegment: 1), "Board")
        control.selectedSegment = 1
        _ = control.sendAction(control.action, to: control.target)
        first.turn()
        first.close()
        XCTAssertEqual(defaults.string(forKey: MacMissionPage.modeKey), MacMissionPageMode.board.rawValue)

        let next = HostedView(MacMissionPageTopBar(backConvoID: nil, onBack: { _ in }, onShowDashboard: {},
                                                   store: defaults))
        defer { next.close() }
        XCTAssertEqual(try XCTUnwrap(next.segmentedControl()).selectedSegment, 1)
        // The next page's content draws exactly what the Board draws.
        XCTAssertEqual(render(MacMissionPageContentHost(model: F.model(), actions: .init(), store: defaults)),
                       render(MacMissionPageContent(model: F.model(), mode: .board, actions: .init())),
                       "the next page opens on the Board")
        XCTAssertNotEqual(render(MacMissionPageContent(model: F.model(), mode: .overview, actions: .init())),
                          render(MacMissionPageContent(model: F.model(), mode: .board, actions: .init())),
                          "the comparison can tell the two views apart")
    }

    private func render<V: View>(_ view: V) -> Data? {
        let host = MacSnapshotHost(view.frame(width: 1_200, height: 900).environment(\.macMissionPageClock, F.now),
                                   appearance: .aqua)
        defer { host.close() }
        return host.pngData()
    }

    // MARK: Board

    /// A card click opens that item — the host's `onOpenItem`, which on
    /// the Mac opens it where every item opens. A real mouse down/up on
    /// the only card (To do's first), not a call into the closure.
    func testABoardCardClickOpensTheItem() throws {
        var opened: [String] = []
        var model = F.model()
        model.openItems = [F.openItems[3]]
        model.closedItems = []
        let host = HostedView(MacMissionBoardView(model: model, onOpenItem: { opened.append($0) })
                                .frame(width: 1_200))
        defer { host.close() }
        // Inside the card: 14pt column padding, the header, then the card.
        host.click(atTopLeftOffset: CGPoint(x: 120, y: 90))
        XCTAssertEqual(opened, ["it_3804"])
        host.click(atTopLeftOffset: CGPoint(x: 120, y: 20))
        XCTAssertEqual(opened, ["it_3804"], "the column header is not a card")
    }
}

/// A SwiftUI view in a real (never ordered-in) window, so AppKit controls
/// and the accessibility tree exist.
@MainActor
private final class HostedView {
    let window: NSWindow
    let host: NSView

    init<V: View>(_ view: V) {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: max(size.width, 600), height: max(size.height, 200)))
        window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        host = hosting
        turn()
    }

    func turn() {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
    }

    func close() { window.close() }

    func segmentedControl() -> NSSegmentedControl? { Self.find(NSSegmentedControl.self, in: host) }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }

    /// A left click at a point measured from the view's top-left corner.
    func click(atTopLeftOffset point: CGPoint) {
        // Ordered in (off every screen) so the window takes events at all.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        turn()
        let location = NSPoint(x: point.x, y: host.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            window.sendEvent(event!)
        }
        turn()
    }
}
#endif
