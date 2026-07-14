import XCTest
import MatronChat
import MatronModels
@testable import MatronViewModels

/// Pins the terminal-style sent-message recall contract:
/// `SentMessageHistory` (record + cap + consecutive-dedupe, Up/Down walk,
/// draft stash/restore, per-room isolation) and the `ComposerViewModel`
/// wiring on top of it (record-on-send, edit-exits-navigation).
///
/// `FakeTimelineService` is defined in `ComposerViewModelTests.swift` in
/// this same test target.
final class SentMessageHistoryTests: XCTestCase {

    // MARK: - SentMessageHistory (model)

    @MainActor
    func test_record_appendsAndRecallsMostRecentFirst() {
        let history = SentMessageHistory()
        history.record("first", room: "!a")
        history.record("second", room: "!a")
        // First Up returns the most recent sent message.
        XCTAssertEqual(history.recallOlder(room: "!a", currentDraft: ""), "second")
        // Next Up walks back to the older one.
        XCTAssertEqual(history.recallOlder(room: "!a", currentDraft: ""), "first")
        // No older entry: nil, so the caller leaves the field unchanged.
        XCTAssertNil(history.recallOlder(room: "!a", currentDraft: ""))
    }

    @MainActor
    func test_record_dedupesConsecutiveDuplicates() {
        let history = SentMessageHistory()
        history.record("hi", room: "!a")
        history.record("hi", room: "!a")   // consecutive dup — collapsed
        history.record("bye", room: "!a")
        history.record("hi", room: "!a")   // non-consecutive — kept

        XCTAssertEqual(history.recallOlder(room: "!a", currentDraft: ""), "hi")
        XCTAssertEqual(history.recallOlder(room: "!a", currentDraft: ""), "bye")
        XCTAssertEqual(history.recallOlder(room: "!a", currentDraft: ""), "hi")
        XCTAssertNil(history.recallOlder(room: "!a", currentDraft: ""),
                     "only three distinct consecutive entries should remain")
    }

    @MainActor
    func test_record_capsAtFiftyDroppingOldest() {
        let history = SentMessageHistory()
        for i in 1...60 { history.record("msg\(i)", room: "!a") }
        // Walk all the way back and count how many distinct entries survive.
        var recalled: [String] = []
        while let text = history.recallOlder(room: "!a", currentDraft: "") {
            recalled.append(text)
        }
        XCTAssertEqual(recalled.count, 50, "history should cap at 50 per room")
        XCTAssertEqual(recalled.first, "msg60", "newest is recalled first")
        XCTAssertEqual(recalled.last, "msg11", "oldest surviving entry is msg11 (msg1–10 dropped)")
    }

    @MainActor
    func test_recallNewer_walksForwardThenRestoresStashedDraft() {
        let history = SentMessageHistory()
        history.record("one", room: "!a")
        history.record("two", room: "!a")

        // Begin a walk while a draft is in progress.
        XCTAssertEqual(history.recallOlder(room: "!a", currentDraft: "draft"), "two")
        XCTAssertEqual(history.recallOlder(room: "!a", currentDraft: "draft"), "one")
        XCTAssertTrue(history.isNavigating)

        // Down walks forward toward newer, then restores the stash.
        XCTAssertEqual(history.recallNewer(room: "!a"), "two")
        XCTAssertEqual(history.recallNewer(room: "!a"), "draft",
                       "stepping past the newest restores the stashed draft")
        XCTAssertFalse(history.isNavigating, "restoring the draft ends the walk")
        XCTAssertNil(history.recallNewer(room: "!a"), "Down does nothing once the walk has ended")
    }

    @MainActor
    func test_recallOlder_returnsNil_forEmptyHistory() {
        let history = SentMessageHistory()
        XCTAssertNil(history.recallOlder(room: "!a", currentDraft: "draft"))
        XCTAssertFalse(history.isNavigating)
    }

    @MainActor
    func test_history_isIsolatedPerRoom() {
        let history = SentMessageHistory()
        history.record("A-only", room: "!a")
        history.record("B-only", room: "!b")

        XCTAssertEqual(history.recallOlder(room: "!a", currentDraft: ""), "A-only")
        XCTAssertNil(history.recallOlder(room: "!a", currentDraft: ""),
                     "room A must not see room B's history")
        // Starting a walk in a different room is a fresh walk, not a
        // continuation of room A's.
        XCTAssertEqual(history.recallOlder(room: "!b", currentDraft: ""), "B-only")
    }

    @MainActor
    func test_endRecall_isIdempotentAndResetsWalk() {
        let history = SentMessageHistory()
        history.record("x", room: "!a")
        _ = history.recallOlder(room: "!a", currentDraft: "d")
        XCTAssertTrue(history.isNavigating)
        history.endRecall()
        XCTAssertFalse(history.isNavigating)
        history.endRecall()  // idempotent
        XCTAssertFalse(history.isNavigating)
    }

    // MARK: - ComposerViewModel wiring

    @MainActor
    func test_send_recordsIntoHistory_recallableViaUp() async {
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!r", timeline: fake, commands: [])
        vm.input = "  hello  "
        await vm.send()
        XCTAssertEqual(vm.input, "")
        XCTAssertFalse(vm.isNavigatingHistory)

        // Up on the now-empty field recalls the trimmed sent text.
        vm.recallOlder()
        XCTAssertEqual(vm.input, "hello")
        XCTAssertTrue(vm.isNavigatingHistory)
    }

    @MainActor
    func test_recallOlder_onEmptyHistory_isNoOp() {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(), commands: [])
        vm.recallOlder()
        XCTAssertEqual(vm.input, "")
        XCTAssertFalse(vm.isNavigatingHistory)
    }

    @MainActor
    func test_recallUpDown_walksAndRestoresInProgressDraft() async {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(), commands: [])
        vm.input = "first"; await vm.send()
        vm.input = "second"; await vm.send()

        // Type a fresh in-progress draft, then walk history.
        vm.input = "wip"
        vm.handleInputChange()  // user edit — nothing to exit yet
        vm.recallOlder()
        XCTAssertEqual(vm.input, "second")
        vm.recallOlder()
        XCTAssertEqual(vm.input, "first")

        vm.recallNewer()
        XCTAssertEqual(vm.input, "second")
        vm.recallNewer()
        XCTAssertEqual(vm.input, "wip", "walking past the newest restores the stashed draft")
        XCTAssertFalse(vm.isNavigatingHistory)
    }

    @MainActor
    func test_userEdit_exitsNavigation() async {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(), commands: [])
        vm.input = "sent"; await vm.send()

        vm.recallOlder()
        XCTAssertEqual(vm.input, "sent")
        XCTAssertTrue(vm.isNavigatingHistory)

        // Simulate a keystroke: the value changes, then the view's onChange
        // fires. Navigation must exit so Down stops walking history.
        vm.input = "sentX"
        vm.handleInputChange()
        XCTAssertFalse(vm.isNavigatingHistory, "a user edit exits history navigation")

        // Down is now a no-op (not navigating), leaving the edit intact.
        vm.recallNewer()
        XCTAssertEqual(vm.input, "sentX")
    }

    @MainActor
    func test_programmaticRecallWrite_doesNotExitNavigation() async {
        // The recall write itself sets `input`; the deferred onChange that
        // follows must not be mistaken for a user edit.
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(), commands: [])
        vm.input = "a"; await vm.send()
        vm.input = "b"; await vm.send()

        vm.recallOlder()               // input -> "b"
        vm.handleInputChange()         // deferred onChange for the recall write
        XCTAssertTrue(vm.isNavigatingHistory, "our own recall write must not exit navigation")
        vm.recallOlder()               // still navigating -> "a"
        XCTAssertEqual(vm.input, "a")
    }

    @MainActor
    func test_cancelRecall_returnsStashedDraft_andEndsWalk() {
        let history = SentMessageHistory()
        history.record("sent", room: "!a")
        XCTAssertEqual(history.recallOlder(room: "!a", currentDraft: "half-typed"), "sent")

        XCTAssertEqual(history.cancelRecall(), "half-typed")
        XCTAssertFalse(history.isNavigating)
        // No walk active any more: a second cancel is a no-op nil.
        XCTAssertNil(history.cancelRecall())
    }

    @MainActor
    func test_exitHistoryNavigation_restoresDraft_forPersistence() async {
        // The composer view calls this on disappear before persisting the
        // draft — mid-walk, `input` shows a recalled sent line, and storing
        // that would clobber the user's real in-progress draft.
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(), commands: [])
        vm.input = "sent"; await vm.send()

        vm.input = "half-typed draft"
        vm.handleInputChange()
        vm.recallOlder()
        XCTAssertEqual(vm.input, "sent")

        vm.exitHistoryNavigation()
        XCTAssertEqual(vm.input, "half-typed draft", "disappear mid-walk must persist the draft, not the recalled line")
        XCTAssertFalse(vm.isNavigatingHistory)

        // Outside navigation it's a no-op.
        vm.exitHistoryNavigation()
        XCTAssertEqual(vm.input, "half-typed draft")
    }
}
