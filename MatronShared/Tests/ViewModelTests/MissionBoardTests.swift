import XCTest
import MatronModels

/// The Mac mission page's Board rules (`MissionBoard`).
final class MissionBoardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func item(_ num: Int, kind: ItemKind = .task, state: ItemState = .open, resolution: ItemResolution? = nil,
                      awaiting: ItemAwaiting? = nil, created: TimeInterval = 100_000, updated: TimeInterval = 0,
                      closed: TimeInterval? = nil, convo: String = "c1") -> TrackerItem {
        TrackerItem(id: "it_\(num)", num: num, kind: kind, state: state, resolution: resolution, awaiting: awaiting,
                    title: "Item \(num)", originConvoID: convo, createdAt: ago(created), updatedAt: ago(updated),
                    closedAt: closed.map(ago))
    }

    // MARK: Columns

    /// To do = awaiting you (first) then awaiting nobody; In progress =
    /// awaiting the agent; Done = closed, whatever `awaiting` still says.
    func testEachItemLandsInItsColumn() {
        let board = MissionBoard.assemble(
            open: [item(1, awaiting: .agent), item(2, kind: .question, awaiting: .user), item(3)],
            closed: [item(4, state: .closed, resolution: .done, awaiting: .user, closed: 10)],
            doneLimit: 10)
        XCTAssertEqual(board.toDo.map(\.num), [2, 3])
        XCTAssertEqual(board.inProgress.map(\.num), [1])
        XCTAssertEqual(board.done.map(\.num), [4])
        XCTAssertEqual(board.moreDone, 0)
    }

    /// Needs-you cards sort before not-started ones even when older; each
    /// group newest `updatedAt` first, the higher number breaking a tie.
    func testToDoPutsNeedsYouFirstThenNewestFirst() {
        let board = MissionBoard.assemble(
            open: [
                item(1, updated: 10),                                    // not started, newest
                item(2, kind: .question, awaiting: .user, updated: 5_000),
                item(3, kind: .question, awaiting: .user, updated: 60),
                item(4, updated: 900),
                item(5, updated: 900),
            ],
            closed: [], doneLimit: 10)
        XCTAssertEqual(board.toDo.map(\.num), [3, 2, 1, 5, 4])
    }

    func testInProgressIsNewestFirst() {
        let board = MissionBoard.assemble(
            open: [item(1, awaiting: .agent, updated: 600), item(2, awaiting: .agent, updated: 30),
                   item(3, awaiting: .agent, updated: 600)],
            closed: [], doneLimit: 10)
        XCTAssertEqual(board.inProgress.map(\.num), [2, 3, 1])
    }

    /// Done: most recently CLOSED first (`updatedAt` for a row with no
    /// `closedAt`), capped, the rest counted for "Show more"; the header
    /// counts every closed item.
    func testDoneIsNewestClosedFirstAndCapped() {
        let closed = [
            item(1, state: .closed, resolution: .done, updated: 1, closed: 500),
            item(2, state: .closed, resolution: .answered, updated: 900, closed: 20),
            item(3, state: .closed, resolution: .cancelled, updated: 100, closed: nil),
            item(4, state: .closed, resolution: .decided, updated: 5, closed: 3_000),
        ]
        let board = MissionBoard.assemble(open: [], closed: closed, doneLimit: 2)
        XCTAssertEqual(board.done.map(\.num), [2, 3])
        XCTAssertEqual(board.moreDone, 2)
        XCTAssertEqual(board.count(of: .done), 4)
        let more = MissionBoard.assemble(open: [], closed: closed, doneLimit: 2 + MissionBoard.donePageSize)
        XCTAssertEqual(more.done.map(\.num), [2, 3, 1, 4])
        XCTAssertEqual(more.moreDone, 0)
        XCTAssertEqual(MissionBoard.assemble(open: [], closed: closed, doneLimit: -1).done, [])
    }

    /// `closed` can be a loaded prefix: the Done count and "Show more"
    /// follow the mission's real total, not the rows that happen to be
    /// loaded.
    func testDoneCountsTheRealTotalPastTheLoadedRows() {
        let loaded = (1...3).map { item($0, state: .closed, resolution: .done, closed: TimeInterval($0) * 60) }
        let board = MissionBoard.assemble(open: [], closed: loaded, closedTotal: 250, doneLimit: 10)
        XCTAssertEqual(board.done.count, 3)
        XCTAssertEqual(board.moreDone, 247)
        XCTAssertEqual(board.count(of: .done), 250)
        let stale = MissionBoard.assemble(open: [], closed: loaded, closedTotal: 1, doneLimit: 2)
        XCTAssertEqual(stale.count(of: .done), 3, "a count behind the loaded rows never under-reports")
        XCTAssertEqual(stale.moreDone, 1)
    }

    /// The count stream can land before the closed-items stream: the
    /// header already counts them, but the column is loading, not empty,
    /// and has no "Show more" (nothing shown yet to show more past).
    func testAKnownTotalWithNothingLoadedIsLoadingNotShowMore() {
        let board = MissionBoard.assemble(open: [], closed: [], closedTotal: 3, doneLimit: 10)
        XCTAssertEqual(board.count(of: .done), 3)
        XCTAssertTrue(board.isDoneLoading)
        XCTAssertFalse(board.showsMoreDone)
        let loaded = (1...3).map { item($0, state: .closed, resolution: .done, closed: TimeInterval($0) * 60) }
        let partial = MissionBoard.assemble(open: [], closed: loaded, closedTotal: 5, doneLimit: 10)
        XCTAssertFalse(partial.isDoneLoading)
        XCTAssertTrue(partial.showsMoreDone, "rows shown and more to come: Show more")
        let none = MissionBoard.assemble(open: [], closed: [], closedTotal: 0, doneLimit: 10)
        XCTAssertFalse(none.isDoneLoading, "nothing closed is empty, not loading")
        XCTAssertFalse(none.showsMoreDone)
    }

    /// Mid-transition an item can sit in both lists: the newer row wins and
    /// its own state picks the column — it is never on the board twice.
    func testAnItemInBothListsAppearsOnceWhereItsNewestRowSays() {
        let stillOpen = item(1, awaiting: .agent, updated: 600)
        let nowClosed = item(1, state: .closed, resolution: .done, updated: 10, closed: 10)
        let board = MissionBoard.assemble(open: [stillOpen], closed: [nowClosed], doneLimit: 10)
        XCTAssertEqual(board.inProgress, [])
        XCTAssertEqual(board.done.map(\.num), [1])
        let reopened = MissionBoard.assemble(open: [item(1, awaiting: .user, updated: 5)], closed: [nowClosed], doneLimit: 10)
        XCTAssertEqual(reopened.toDo.map(\.num), [1])
        XCTAssertEqual(reopened.done, [])
    }

    /// A consent ask is a question item like any other: its `awaiting`
    /// decides the column, and questions/decisions/tasks mix freely.
    func testKindsDoNotChangeTheColumn() {
        let board = MissionBoard.assemble(
            open: [item(1, kind: .question, awaiting: .agent), item(2, kind: .decision, awaiting: .user),
                   item(3, kind: .task, awaiting: .user)],
            closed: [], doneLimit: 10)
        XCTAssertEqual(Set(board.toDo.map(\.num)), [2, 3])
        XCTAssertEqual(board.inProgress.map(\.num), [1])
    }

    // MARK: Meta line

    func testMetaLines() {
        XCTAssertEqual(MissionBoard.meta(for: item(1, awaiting: .user, updated: 3 * 3_600), boxName: "dan-mac", now: now),
                       "Needs you · 3h")
        XCTAssertEqual(MissionBoard.meta(for: item(2, created: 14 * 3_600), boxName: nil, now: now),
                       "Not started · 14h")
        XCTAssertEqual(MissionBoard.meta(for: item(8, kind: .decision, created: 14 * 3_600), boxName: nil, now: now),
                       "Decision · 14h", "an open decision awaiting nobody is a record, not unstarted work")
        XCTAssertEqual(MissionBoard.meta(for: item(3, awaiting: .agent, updated: 20 * 60), boxName: "dan-mac", now: now),
                       "dan-mac · 20m")
        XCTAssertEqual(MissionBoard.meta(for: item(4, awaiting: .agent, updated: 20 * 60), boxName: nil, now: now),
                       "Agent · 20m")
        XCTAssertEqual(MissionBoard.meta(for: item(4, awaiting: .agent, updated: 20 * 60), boxName: "", now: now),
                       "Agent · 20m")
        XCTAssertEqual(MissionBoard.meta(for: item(5, state: .closed, resolution: .answered, closed: 30 * 60),
                                         boxName: nil, now: now), "Answered · 30m ago")
        XCTAssertEqual(MissionBoard.meta(for: item(6, state: .closed, resolution: .cancelled, closed: 20),
                                         boxName: nil, now: now), "Cancelled · just now")
        XCTAssertEqual(MissionBoard.meta(for: item(7, state: .closed, closed: 2 * 86_400), boxName: nil, now: now),
                       "Closed · 2d ago")
    }

    func testAgoBuckets() {
        XCTAssertEqual(MissionBoard.ago(ago(59), now: now), "now")
        XCTAssertEqual(MissionBoard.ago(ago(60), now: now), "1m")
        XCTAssertEqual(MissionBoard.ago(ago(3_599), now: now), "59m")
        XCTAssertEqual(MissionBoard.ago(ago(3_600), now: now), "1h")
        XCTAssertEqual(MissionBoard.ago(ago(86_400), now: now), "1d")
        XCTAssertEqual(MissionBoard.ago(ago(86_400 * 7), now: now), "1w")
        XCTAssertEqual(MissionBoard.ago(now.addingTimeInterval(120), now: now), "now", "a future date is not negative")
    }
}
