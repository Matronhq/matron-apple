#if os(macOS)
import XCTest
import MatronModels
@testable import MatronMac

/// A session an agent or a routine started used to take
/// the sidebar selection the moment it existed. Only a session started
/// from this Mac may do that now; any other is marked new in the list.
@MainActor
final class MacNewConversationArrivalTests: XCTestCase {
    func test_sessionNotStartedHere_isMarkedNew_neverOpened() {
        let born = NewConversation(id: "spawned", startedHere: false)
        XCTAssertEqual(MacChatListView.arrival(of: born, selected: "reading"), .markNew)
        XCTAssertEqual(MacChatListView.arrival(of: born, selected: nil), .markNew,
                       "an empty detail column is not an invitation either")
    }

    func test_sessionStartedHere_opens() {
        let born = NewConversation(id: "mine", startedHere: true)
        XCTAssertEqual(MacChatListView.arrival(of: born, selected: "reading"), .open)
        XCTAssertEqual(MacChatListView.arrival(of: born, selected: nil), .open)
    }

    /// One already selected is not new: the user is looking at it.
    func test_quietArrivalAlreadySelected_isLeftAlone() {
        let born = NewConversation(id: "open", startedHere: false)
        XCTAssertEqual(MacChatListView.arrival(of: born, selected: "open"), .ignore)
    }
}
#endif
