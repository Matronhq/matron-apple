#if os(macOS)
import XCTest
import AppKit
@testable import MatronMac
import MatronModels

/// A consent ask's answers under its native For you row: drawn only on the
/// Needs you tab for an open ask whose every button is a one-tap answer,
/// lined up with the row's text, and each one answers with its label.
@MainActor
final class MacItemRowCellAnswersTests: XCTestCase {
    private func ask(actions: [String] = ["Approve", "Decline"], awaiting: ItemAwaiting = .user) -> TrackerItem {
        TrackerItem(id: "a1", num: 430, kind: .question, awaiting: awaiting, title: "box-b asks to chat with box-a",
                    labels: ["consent"], links: [TrackerLink(url: "matron://consent/chat/room-1/4")],
                    originConvoID: "c1", actions: actions)
    }

    private func cell(_ item: TrackerItem, isClosedTab: Bool = false) -> MacItemRowCell {
        let cell = MacItemRowCell(frame: NSRect(x: 0, y: 0, width: 380, height: 100))
        cell.configure(item, origin: "Review", isClosedTab: isClosedTab, now: Date())
        cell.frame.size.height = MacItemRowCell.height(for: item, origin: "Review", isClosedTab: isClosedTab, width: 380)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    func test_answersShowUnderTheRow_andTapsSayTheirLabel() {
        var tapped: [String] = []
        let cell = cell(ask())
        cell.onAnswer = { tapped.append($0) }
        XCTAssertEqual(cell.answers, ["Approve", "Decline"])
        let visible = cell.answerButtons.filter { !$0.isHidden }
        XCTAssertEqual(visible.map(\.title), ["Approve", "Decline"])
        XCTAssertNotNil(visible[0].bezelColor, "Approve is filled")
        XCTAssertNil(visible[1].bezelColor, "Decline is bordered")
        let layout = MacItemRowCell.layout(for: ask(), origin: "Review", closedCaption: nil, showsSeen: false,
                                           answers: cell.answers, width: 380)
        XCTAssertEqual(layout.answers.first?.minX, layout.num.minX, "lined up with the text")
        XCTAssertGreaterThan(layout.answers.first?.minY ?? 0, layout.caption.first?.frame.maxY ?? .infinity,
                             "on a line under the row")
        visible[1].performClick(nil)
        XCTAssertEqual(tapped, ["Decline"])
    }

    func test_noAnswers_forARowThatCannotBeAnsweredInOneTap() {
        XCTAssertEqual(cell(ask(actions: ["Accept", "Pick a box", "Decline"])).answers, [])
        XCTAssertEqual(cell(ask(awaiting: .agent)).answers, [])
        XCTAssertEqual(cell(ask(), isClosedTab: true).answers, [])
        let withAnswers = MacItemRowCell.height(for: ask(), origin: "Review", isClosedTab: false, width: 380)
        let without = MacItemRowCell.height(for: ask(actions: []), origin: "Review", isClosedTab: false, width: 380)
        XCTAssertGreaterThan(withAnswers, without, "the answers' line adds to the row")
    }

    func test_theItemsPaneDrawsNoAnswers() {
        let presentation = MacItemRowCell.Presentation(style: .pane, origin: nil, isClosedTab: false, offersSeen: false,
                                                       offersAnswers: false)
        XCTAssertEqual(presentation.answers(ask()), [])
    }
}
#endif
