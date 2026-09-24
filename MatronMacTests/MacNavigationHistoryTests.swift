#if os(macOS)
import XCTest
@testable import MatronMac

/// The pure history model behind the window's Back/Forward (spec §2) and
/// the pane-route helper the chat view syncs through (spec §3).
@MainActor
final class MacNavigationHistoryTests: XCTestCase {
    private let a = MacPlace(detail: .conversation(id: "c1", pane: nil))
    private let b = MacPlace(detail: .mission(id: "m1"))
    private let c = MacPlace(detail: .decision(id: "it_9"))

    func test_empty_hasNothingToGoTo() {
        let history = MacNavigationHistory()
        XCTAssertNil(history.current)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.goBack())
        XCTAssertNil(history.goForward())
    }

    func test_visit_recordsThePreviousPlaceAndClearsForward() {
        let history = MacNavigationHistory()
        history.visit(a)
        XCTAssertEqual(history.current, a)
        XCTAssertFalse(history.canGoBack, "the first place has nothing before it")
        history.visit(b)
        XCTAssertEqual(history.back, [a])
        XCTAssertTrue(history.canGoBack)
        XCTAssertEqual(history.goBack(), a)
        XCTAssertEqual(history.forward, [b])
        // A new branch drops forward, as in a browser.
        history.visit(c)
        XCTAssertEqual(history.forward, [])
        XCTAssertEqual(history.back, [a])
        XCTAssertEqual(history.current, c)
    }

    func test_visitingTheCurrentPlace_isANoOp() {
        let history = MacNavigationHistory()
        history.visit(a)
        history.visit(b)
        history.visit(b)
        XCTAssertEqual(history.back, [a])
        XCTAssertEqual(history.current, b)
    }

    /// The contract the shell relies on: `goBack` sets `current` to the
    /// returned place BEFORE the shell restores it, so the restore's own
    /// `visit` of that place records nothing.
    func test_goBack_setsCurrent_soRestoringDoesNotRecord() {
        let history = MacNavigationHistory()
        history.visit(a)
        history.visit(b)
        let restored = history.goBack()
        XCTAssertEqual(restored, a)
        XCTAssertEqual(history.current, a)
        history.visit(a)   // the shell's onChange after restoring
        XCTAssertEqual(history.back, [], "restoring must not push")
        XCTAssertEqual(history.forward, [b], "restoring must not drop forward")
    }

    func test_goForward_roundTrips() {
        let history = MacNavigationHistory()
        history.visit(a)
        history.visit(b)
        _ = history.goBack()
        XCTAssertEqual(history.goForward(), b)
        XCTAssertEqual(history.current, b)
        XCTAssertEqual(history.back, [a])
        XCTAssertFalse(history.canGoForward)
    }

    /// Review focus 1: two presses before any re-render walk two steps.
    func test_goBackTwice_returnsSuccessivePlaces() {
        let history = MacNavigationHistory()
        history.visit(a)
        history.visit(b)
        history.visit(c)
        XCTAssertEqual(history.goBack(), b)
        XCTAssertEqual(history.goBack(), a)
        XCTAssertEqual(history.forward, [c, b])
        XCTAssertNil(history.goBack())
    }

    func test_capacity_dropsTheOldest() {
        let history = MacNavigationHistory()
        for i in 0...(MacNavigationHistory.capacity + 5) {
            history.visit(MacPlace(detail: .conversation(id: "c\(i)", pane: nil)))
        }
        XCTAssertEqual(history.back.count, MacNavigationHistory.capacity)
        XCTAssertEqual(history.back.first, MacPlace(detail: .conversation(id: "c5", pane: nil)))
    }

    // MARK: Pane route helper

    func test_paneRouteFrom_subChatWins_thenItems_thenNil() {
        XCTAssertEqual(MacChatPaneRoute.from(itemsOpen: true, path: ["it_1"], subChatID: "s1"), .subChat(id: "s1"))
        XCTAssertEqual(MacChatPaneRoute.from(itemsOpen: true, path: ["it_1"], subChatID: nil), .items(path: ["it_1"]))
        XCTAssertEqual(MacChatPaneRoute.from(itemsOpen: false, path: ["it_1"], subChatID: nil), nil)
    }

    func test_place_navAndPaneAccessors() {
        let route = MacChatPaneRoute.items(path: ["it_1"])
        XCTAssertEqual(MacPlace(detail: .coordinator(pane: route)).nav, .coordinator)
        XCTAssertEqual(MacPlace(detail: .coordinator(pane: route)).pane, route)
        XCTAssertEqual(MacPlace(detail: .conversation(id: "c1", pane: route)).nav, .conversations)
        XCTAssertEqual(MacPlace(detail: .mission(id: nil)).nav, .missions)
        XCTAssertNil(MacPlace(detail: .mission(id: nil)).pane)
        XCTAssertEqual(MacPlace(detail: .decision(id: "d")).nav, .decisions)
    }

    func test_place_displayedConversation() {
        XCTAssertEqual(MacPlace(detail: .conversation(id: "c1", pane: nil)).displayedConversationID(coordinatorConvoID: "k"), "c1")
        XCTAssertEqual(MacPlace(detail: .coordinator(pane: nil)).displayedConversationID(coordinatorConvoID: "k"), "k")
        XCTAssertNil(MacPlace(detail: .coordinator(pane: nil)).displayedConversationID(coordinatorConvoID: nil))
        XCTAssertNil(MacPlace(detail: .coordinator(pane: nil)).displayedConversationID(coordinatorConvoID: ""))
        XCTAssertNil(MacPlace(detail: .mission(id: "m")).displayedConversationID(coordinatorConvoID: "k"))
        XCTAssertNil(MacPlace(detail: .conversation(id: nil, pane: nil)).displayedConversationID(coordinatorConvoID: "k"))
    }
}
#endif
