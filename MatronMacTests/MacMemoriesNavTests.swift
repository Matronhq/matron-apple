import XCTest
import MatronModels
@testable import MatronMac

/// The Memories nav entry (spec 2026-09-27 memories; decision #3948).
@MainActor
final class MacMemoriesNavTests: XCTestCase {
    func testTheEntryIsLastAndAlwaysShown() {
        XCTAssertEqual(MacNav.allCases.last, .memories)
        XCTAssertEqual(MacNav.memories.title, "Memories")
        XCTAssertEqual(MacNav.memories.symbol, "brain")
        // Unlike Missions, an old journal doesn't hide it: its 404 shows on
        // the entry's own screen.
        XCTAssertTrue(MacNavColumn.entries(missionsSupported: false).contains(.memories))
    }

    func testThePlaceCarriesOnlyTheMemorySelection() {
        func place(_ selection: MacMemorySelection?) -> MacPlace {
            MacChatListView.place(nav: .memories, selectedSummaryID: "c1", selectedMissionID: "ms_1",
                                  selectedDecisionID: "it_1", paneRoute: .items(path: []),
                                  coordinatorConvoID: "coord", selectedMemory: selection)
        }
        XCTAssertEqual(place(.memory("avoid-eric")), MacPlace(detail: .memory(.memory("avoid-eric"))))
        XCTAssertEqual(place(.new), MacPlace(detail: .memory(.new)))
        XCTAssertEqual(place(nil), MacPlace(detail: .memory(nil)))
        XCTAssertEqual(place(nil).nav, .memories)
        XCTAssertNil(place(.new).pane)
        XCTAssertNil(place(.new).displayedConversationID)
        // Another entry never records the memory selection.
        XCTAssertEqual(MacChatListView.place(nav: .missions, selectedSummaryID: nil, selectedMissionID: "ms_1",
                                             selectedDecisionID: nil, paneRoute: nil, coordinatorConvoID: nil,
                                             selectedMemory: .memory("avoid-eric")),
                       MacPlace(detail: .mission(id: "ms_1")))
    }

    /// Picking memories records places, so Back walks between them.
    func testMemoryPlacesAreHistoryEntries() {
        let history = MacNavigationHistory()
        history.visit(MacPlace(detail: .memory(nil)))
        history.visit(MacPlace(detail: .memory(.memory("avoid-eric"))))
        history.visit(MacPlace(detail: .memory(.new)))
        XCTAssertEqual(history.goBack(), MacPlace(detail: .memory(.memory("avoid-eric"))))
        XCTAssertEqual(history.goBack(), MacPlace(detail: .memory(nil)))
    }

    func testTheEntryMountsNoChatAndHasNoFindTarget() {
        XCTAssertNil(MacChatListView.detailChatID(nav: .memories, selectedSummaryID: "c1",
                                                  coordinatorConvoID: nil, isStaleRestore: false))
        XCTAssertNil(MacChatListView.mainChatForFind(nav: .memories, searchResultsShown: false,
                                                     detailChatID: "c1", columnShown: true))
    }

    /// After a save, as the web tracker does: a new memory opens in its
    /// editor; an edit returns to the list.
    func testSelectionAfterSaving() {
        XCTAssertEqual(MacMemoryDetail.selection(afterSavingNew: true, name: "avoid-eric"), .memory("avoid-eric"))
        XCTAssertNil(MacMemoryDetail.selection(afterSavingNew: false, name: "avoid-eric"))
        XCTAssertEqual(MacMemorySelection.memory("avoid-eric").name, "avoid-eric")
        XCTAssertNil(MacMemorySelection.new.name)
    }

    /// A box file is a place like any memory: Back returns from it, and it
    /// highlights no journal row.
    func testABoxFileIsASelectionAndAHistoryEntry() {
        let ref = LocalMemoryRef(boxID: 42, path: "/home/dan/app/CLAUDE.md")
        XCTAssertEqual(MacMemorySelection.local(ref).localRef, ref)
        XCTAssertNil(MacMemorySelection.local(ref).name)
        XCTAssertNil(MacMemorySelection.memory("avoid-eric").localRef)
        let history = MacNavigationHistory()
        history.visit(MacPlace(detail: .memory(.memory("avoid-eric"))))
        history.visit(MacPlace(detail: .memory(.local(ref))))
        history.visit(MacPlace(detail: .memory(nil)))
        XCTAssertEqual(history.goBack(), MacPlace(detail: .memory(.local(ref))))
        XCTAssertEqual(history.goBack(), MacPlace(detail: .memory(.memory("avoid-eric"))))
    }
}
