#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import MatronMac

/// Back/Forward reach every way the user moves around a window: they are
/// always drawn (greyed out with nowhere to go), a pane's own close or
/// Back is a step back rather than a new place, and the mouse's side
/// buttons and trackpad swipes step through the same history.
@MainActor
final class MacHistoryEverywhereTests: XCTestCase {
    private let chat = MacPlace(detail: .conversation(id: "c1", pane: nil))
    private let tasks = MacPlace(detail: .conversation(id: "c1", pane: .items(path: [])))
    private let item = MacPlace(detail: .conversation(id: "c1", pane: .items(path: ["it_1"])))
    private let nested = MacPlace(detail: .conversation(id: "c1", pane: .items(path: ["it_1", "it_2"])))
    private let subChat = MacPlace(detail: .conversation(id: "c1", pane: .subChat(id: "c1-child")))
    private let other = MacPlace(detail: .conversation(id: "c2", pane: nil))
    private let mission = MacPlace(detail: .mission(id: "m1"))

    // MARK: Always drawn

    func test_header_carriesBackForward_whereverTheSidebarToolbarCannot() {
        for nav in [MacNav.coordinator, .missions, .desk("d1")] {
            XCTAssertTrue(MacChatListView.headerCarriesNavigation(nav: nav, columnVisibility: .automatic),
                          "\(nav): the 72 pt sidebar has no toolbar room")
        }
        for nav in [MacNav.conversations, .decisions, .memories] {
            XCTAssertFalse(MacChatListView.headerCarriesNavigation(nav: nav, columnVisibility: .automatic),
                           "\(nav): the sidebar toolbar draws them")
            XCTAssertTrue(MacChatListView.headerCarriesNavigation(nav: nav, columnVisibility: .detailOnly),
                          "\(nav): a collapsed sidebar takes its toolbar with it, so the header must draw them")
        }
    }

    /// For you with an item open and the sidebar collapsed: the item's ⋯
    /// used to replace the whole strip, Back/Forward included.
    func test_itemHeader_keepsTheBackForwardCapsule_whenTheHeaderCarriesThem() async throws {
        let without = try await Self.leadingCapsule(itemWithChrome: false)
        XCTAssertNil(without, "with the sidebar toolbar drawing them, the item strip adds no chevrons")
        let with = try await Self.leadingCapsule(itemWithChrome: true)
        let capsule = try XCTUnwrap(with, "Back/Forward must be drawn beside the open item")
        XCTAssertLessThan(capsule.minX, 20, "at the header's leading edge")
    }

    private static func leadingCapsule(itemWithChrome: Bool) async throws -> CGRect? {
        let model = MacChatHeaderModel()
        model.item = MacItemHeaderProps(itemID: "it_1", publisher: ObjectIdentifier(model), isOpen: true,
                                        resolutions: [], isBusy: false, canReopen: false,
                                        onClose: { _ in }, onReopen: {})
        if itemWithChrome {
            model.coordinatorPage = MacCoordinatorPageChrome(
                navigation: MacNavigationActions(canGoBack: false, canGoForward: false, goBack: {}, goForward: {}),
                newChat: {})
        }
        let regions = MacChatHeaderHitRegions()
        let host = NSHostingView(rootView: MacChatHeaderBar(model: model, hitRegions: regions))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 52),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        let end = Date().addingTimeInterval(itemWithChrome ? 5 : 1)
        while Date() < end, regions.capsules.isEmpty {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return regions.capsules.min { $0.minX < $1.minX }
    }

    // MARK: Pane close and pane Back are steps back

    func test_closingAPane_backToThePreviousPlace_isAStepBack_keepingForward() {
        let history = MacNavigationHistory()
        MacChatListView.record(chat, in: history)
        MacChatListView.record(subChat, in: history)
        MacChatListView.record(chat, in: history)   // the sub-chat's close button
        XCTAssertEqual(history.current, chat)
        XCTAssertEqual(history.back, [])
        XCTAssertEqual(history.forward, [subChat], "Forward reopens what was closed")
    }

    func test_tasksPaneBack_popsTheItem_asAStepBack() {
        let history = MacNavigationHistory()
        MacChatListView.record(chat, in: history)
        MacChatListView.record(tasks, in: history)
        MacChatListView.record(item, in: history)
        MacChatListView.record(nested, in: history)
        MacChatListView.record(item, in: history)   // the pane's own Back chevron
        XCTAssertEqual(history.back, [chat, tasks])
        XCTAssertEqual(history.forward, [nested])
        MacChatListView.record(chat, in: history)   // the pane's close: past two places at once
        XCTAssertEqual(history.current, chat)
        XCTAssertEqual(history.back, [chat, tasks, item], "not the previous place: recorded as a move")
    }

    func test_aPaneClosedThatWasOpenedElsewhere_isStillAMove() {
        let history = MacNavigationHistory()
        MacChatListView.record(other, in: history)
        MacChatListView.record(subChat, in: history)   // a link straight into c1's sub-chat
        MacChatListView.record(chat, in: history)
        XCTAssertEqual(history.back, [other, subChat])
        XCTAssertEqual(history.forward, [])
    }

    func test_goingToThePreviousPlaceSomeOtherWay_isStillAMove() {
        let history = MacNavigationHistory()
        MacChatListView.record(chat, in: history)
        MacChatListView.record(other, in: history)
        MacChatListView.record(chat, in: history)   // a sidebar click back to c1
        XCTAssertEqual(history.back, [chat, other], "Back must still return to c2")
    }

    func test_isRetreat_onlyForTheSamePageLosingItsPane() {
        XCTAssertTrue(subChat.isRetreat(to: chat))
        XCTAssertTrue(item.isRetreat(to: tasks))
        XCTAssertTrue(nested.isRetreat(to: chat))
        XCTAssertFalse(tasks.isRetreat(to: item), "opening an item goes deeper")
        XCTAssertFalse(subChat.isRetreat(to: tasks), "a different pane")
        XCTAssertFalse(subChat.isRetreat(to: other), "a different conversation")
        XCTAssertFalse(chat.isRetreat(to: chat))
        XCTAssertFalse(mission.isRetreat(to: chat))
    }

    func test_retreat_onlyWhenThePlaceIsThePreviousOne() {
        let history = MacNavigationHistory()
        history.visit(chat)
        history.visit(mission)
        XCTAssertFalse(history.retreat(to: other))
        XCTAssertEqual(history.current, mission)
        XCTAssertTrue(history.retreat(to: chat))
        XCTAssertEqual(history.current, chat)
        XCTAssertEqual(history.forward, [mission])
    }

    /// A mission page's "Back to the conversation" steps back only when that
    /// conversation is where Back would go anyway.
    func test_backToTheConversation_isAStepBack_onlyFromThatConversation() {
        let history = MacNavigationHistory()
        history.visit(MacPlace(detail: .conversation(id: "c1", pane: .items(path: []))))
        history.visit(mission)
        XCTAssertTrue(MacChatListView.previousPlaceShows("c1", in: history))
        XCTAssertFalse(MacChatListView.previousPlaceShows("c2", in: history))
        history.visit(MacPlace(detail: .decision(id: "it_1")))
        history.visit(mission)
        XCTAssertFalse(MacChatListView.previousPlaceShows("c1", in: history))
    }

    // MARK: Mouse buttons and swipes

    func test_mouseSideButtons_goBackAndForward() {
        XCTAssertEqual(MacHistoryStep.forMouseButton(3), .back)
        XCTAssertEqual(MacHistoryStep.forMouseButton(4), .forward)
        XCTAssertNil(MacHistoryStep.forMouseButton(2), "the middle button is not a history step")
    }

    func test_swipes_goTheWaySafariDoes() {
        XCTAssertEqual(MacHistoryStep.forSwipe(deltaX: 1), .back)
        XCTAssertEqual(MacHistoryStep.forSwipe(deltaX: -1), .forward)
        XCTAssertNil(MacHistoryStep.forSwipe(deltaX: 0))
        XCTAssertEqual(MacHistoryStep.forTrackedSwipe(amount: 0.8), .back)
        XCTAssertEqual(MacHistoryStep.forTrackedSwipe(amount: -0.8), .forward)
    }

    func test_pageSwipe_startsOnlyForASidewaysTrackpadGesture() {
        XCTAssertTrue(MacHistoryStep.startsPageSwipe(phase: .began, deltaX: 4, deltaY: 1,
                                                     swipeTrackingEnabled: true, overHorizontalScroller: false))
        XCTAssertFalse(MacHistoryStep.startsPageSwipe(phase: .began, deltaX: 1, deltaY: 4,
                                                      swipeTrackingEnabled: true, overHorizontalScroller: false),
                       "scrolling the transcript")
        XCTAssertFalse(MacHistoryStep.startsPageSwipe(phase: .changed, deltaX: 4, deltaY: 1,
                                                      swipeTrackingEnabled: true, overHorizontalScroller: false))
        XCTAssertFalse(MacHistoryStep.startsPageSwipe(phase: .began, deltaX: 4, deltaY: 1,
                                                      swipeTrackingEnabled: false, overHorizontalScroller: false),
                       "the user turned page swipes off")
        XCTAssertFalse(MacHistoryStep.startsPageSwipe(phase: .began, deltaX: 4, deltaY: 1,
                                                      swipeTrackingEnabled: true, overHorizontalScroller: true),
                       "a wide code block keeps its own sideways scroll")
    }
}
#endif
