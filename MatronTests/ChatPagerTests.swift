import XCTest
import SwiftUI
@testable import Matron

/// App shell (spec §4): the chat screen pages between the timeline and the
/// tracker. The model owns the page and the composer-focus rule; the view
/// is a thin paging ScrollView over it.
@MainActor
final class ChatPagerTests: XCTestCase {
    func test_startsOnTheChatPage() {
        XCTAssertEqual(ChatPagerModel(resignComposer: {}).page, .chat)
    }

    func test_checklistButton_goesToTasks_andResignsTheComposer() {
        var resigned = 0
        let model = ChatPagerModel(resignComposer: { resigned += 1 })
        model.go(to: .tasks)
        XCTAssertEqual(model.page, .tasks)
        XCTAssertEqual(resigned, 1)
    }

    func test_returnButton_goesBackToChat_withoutRefocusing() {
        var resigned = 0
        let model = ChatPagerModel(resignComposer: { resigned += 1 })
        model.go(to: .tasks)
        model.go(to: .chat)
        XCTAssertEqual(model.page, .chat)
        XCTAssertEqual(resigned, 1, "paging back never touches the keyboard")
    }

    func test_swipeToTasks_resignsTheComposer_once() {
        var resigned = 0
        let model = ChatPagerModel(resignComposer: { resigned += 1 })
        model.handleScrolled(to: .tasks)
        model.handleScrolled(to: .tasks)
        XCTAssertEqual(model.page, .tasks)
        XCTAssertEqual(resigned, 1, "repeated write-backs for the same page are no-ops")
        model.handleScrolled(to: .chat)
        XCTAssertEqual(model.page, .chat)
        XCTAssertEqual(resigned, 1)
    }

    func test_onSelect_appendsAnItemRouteToTheOuterPath_notALocalStack() {
        var path: [String] = ["!r:s"]
        let binding = Binding(get: { path }, set: { path = $0 })
        ChatView.pushItem("it_1", onto: binding)
        XCTAssertEqual(path, ["!r:s", ItemRoute(id: "it_1").pathValue])
        ChatView.pushItem("it_1", onto: binding)
        XCTAssertEqual(path.count, 2, "a repeat tap on the same item is idempotent")
        ChatView.pushItem("it_2", onto: nil)
        XCTAssertEqual(path.count, 2, "no path (previews/tests) is a no-op")
    }
}
