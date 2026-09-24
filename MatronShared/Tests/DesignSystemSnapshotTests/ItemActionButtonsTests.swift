import SwiftUI
import XCTest
@testable import MatronDesignSystem

/// Pins the item action-button row (contract 2026-09-24): when it draws
/// under the body card (`ItemDetailView.showsActions`), what each button
/// renders as (`ItemActionButtons.states`), and that a long label wraps
/// on a phone-width measure instead of running off the edge.
final class ItemActionButtonsTests: XCTestCase {
    func testShowsForAnOpenItemWithActions() {
        XCTAssertTrue(ItemDetailView.showsActions(["Go"], isOpen: true))
    }

    func testHiddenWithoutActions() {
        XCTAssertFalse(ItemDetailView.showsActions([], isOpen: true))
    }

    func testHiddenOnceClosed() {
        XCTAssertFalse(ItemDetailView.showsActions(["Go", "Wait"], isOpen: false))
    }

    /// One button per action, in order; only the chosen one is marked.
    func testEveryActionIsAButtonAndOnlyTheChosenOneIsMarked() {
        let states = ItemActionButtons.states(actions: ["Go", "Wait", "Stop"], selected: "Wait", isEnabled: true)
        XCTAssertEqual(states.map(\.label), ["Go", "Wait", "Stop"])
        XCTAssertEqual(states.map(\.isChosen), [false, true, false])
        XCTAssertEqual(states.map(\.isEnabled), [true, true, true])
    }

    func testNothingMarkedWithoutAChoice() {
        XCTAssertEqual(ItemActionButtons.states(actions: ["Go", "Wait"], selected: nil, isEnabled: true).map(\.isChosen), [false, false])
    }

    /// Review (PR #242): a close in flight (`isBusy`) disables every
    /// button — a tap racing the close would reopen the item.
    func testBusyDisablesEveryButton() {
        XCTAssertEqual(ItemActionButtons.states(actions: ["Go", "Wait"], selected: "Go", isEnabled: false).map(\.isEnabled), [false, false])
    }

    #if os(macOS)
    /// Review (PR #242): stacked, a 40-character label must give way to
    /// the measure — `.fixedSize()` pinned it to one line wider than a
    /// 375pt phone. Measured by laying the real view out, not by reading
    /// modifiers back.
    @MainActor
    func testALongLabelWrapsToANarrowMeasure() {
        let long = "Ship the release candidate to TestFlight"   // 40 chars
        XCTAssertEqual(long.count, 40)
        let view = ItemActionButtons(actions: [long, "Wait"], selected: long, isEnabled: true, onChoose: { _ in })
        let host = NSHostingController(rootView: view)
        let size = host.sizeThatFits(in: CGSize(width: 200, height: 1000))
        // (AppKit's bordered button truncates where UIKit's wraps, so the
        // Mac pin is the overflow itself: 273pt wide with `.fixedSize()`.)
        XCTAssertLessThanOrEqual(size.width, 200, "the row stays inside the measure (\(size))")
    }
    #endif
}
