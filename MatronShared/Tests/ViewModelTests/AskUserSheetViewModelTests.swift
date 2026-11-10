import XCTest
import MatronChat
import MatronEvents
@testable import MatronViewModels

@MainActor
final class AskUserSheetViewModelTests: XCTestCase {
    private func makeVM(
        event: AskUserEvent,
        timeline: FakeTimelineService = FakeTimelineService(),
        onClose: @escaping () -> Void = {}
    ) -> AskUserSheetViewModel {
        AskUserSheetViewModel(
            event: event,
            promptEventID: "$prompt-1",
            timeline: timeline,
            onClose: onClose
        )
    }

    // MARK: - .textReply channel (ask_user contract, spec §4.2)

    func test_send_passesPromptEventID_asInReplyTo() async {
        let fake = FakeTimelineService()
        let vm = makeVM(
            event: AskUserEvent(prompt: "Which?", kind: .text, expiresAt: nil),
            timeline: fake
        )
        vm.textInput = "src/main.rs"
        await vm.send()
        XCTAssertEqual(fake.sentText, ["src/main.rs"])
        XCTAssertEqual(fake.sentInReplyTo, ["$prompt-1"])
    }

    func test_send_choiceReply_usesOptionLabel() async {
        let fake = FakeTimelineService()
        let opts = [
            AskUserEvent.Option(id: "a", label: "main.rs"),
            AskUserEvent.Option(id: "b", label: "lib.rs"),
        ]
        let vm = makeVM(
            event: AskUserEvent(prompt: "Which file?", kind: .choice(options: opts, allowOther: false), expiresAt: nil),
            timeline: fake
        )
        vm.selectedChoiceIDs = ["b"]
        await vm.send()
        XCTAssertEqual(fake.sentText, ["lib.rs"])
    }

    func test_send_multiChoiceReply_joinsLabels() async {
        let fake = FakeTimelineService()
        let opts = [
            AskUserEvent.Option(id: "a", label: "Build"),
            AskUserEvent.Option(id: "b", label: "Test"),
            AskUserEvent.Option(id: "c", label: "Lint"),
        ]
        let vm = makeVM(
            event: AskUserEvent(prompt: "Steps?", kind: .multiChoice(options: opts, allowOther: false), expiresAt: nil),
            timeline: fake
        )
        vm.selectedChoiceIDs = ["a", "c"]
        await vm.send()
        // Option order (not selection order) so the reply is stable.
        XCTAssertEqual(fake.sentText, ["Build, Lint"])
    }

    func test_send_booleanReply_sendsYesNo() async {
        let fake = FakeTimelineService()
        let vm = makeVM(
            event: AskUserEvent(prompt: "Proceed?", kind: .boolean, expiresAt: nil),
            timeline: fake
        )
        vm.booleanAnswer = true
        await vm.send()
        XCTAssertEqual(fake.sentText, ["Yes"])
    }

    func test_send_isNoop_whenBodyEmpty() async {
        let fake = FakeTimelineService()
        let vm = makeVM(
            event: AskUserEvent(prompt: "?", kind: .text, expiresAt: nil),
            timeline: fake
        )
        vm.textInput = "   "
        await vm.send()
        XCTAssertEqual(fake.sentText, [])
    }

    // MARK: - Double-submit guard (bugbot PR #6 finding)

    func test_send_secondConcurrentCall_isSwallowed() async {
        // While the first send() is suspended on the timeline call, a
        // second Send tap runs on the main actor — the isSending guard
        // must drop it rather than answer the prompt twice.
        let fake = FakeTimelineService()
        fake.sendDelayNanos = 100_000_000
        let vm = makeVM(
            event: AskUserEvent(prompt: "Q?", kind: .text, expiresAt: nil),
            timeline: fake
        )
        vm.textInput = "answer"
        async let first: Void = vm.send()
        async let second: Void = vm.send()
        _ = await (first, second)
        XCTAssertEqual(fake.sentText.count, 1, "concurrent re-tap must not double-answer")
    }

    func test_send_afterSuccess_isNoop() async {
        // A tap landing after success but before the dismiss animation
        // completes must not re-answer (hasSent guard).
        let fake = FakeTimelineService()
        let vm = makeVM(
            event: AskUserEvent(prompt: "Q?", kind: .text, expiresAt: nil),
            timeline: fake
        )
        vm.textInput = "answer"
        await vm.send()
        await vm.send()
        XCTAssertEqual(fake.sentText.count, 1)
    }

    func test_send_afterError_allowsRetry() async {
        // Errors must NOT latch the guard — the sheet stays open for a
        // retry, and the retry goes to the wire.
        let fake = FakeTimelineService()
        fake.nextSendError = URLError(.notConnectedToInternet)
        let vm = makeVM(
            event: AskUserEvent(prompt: "Q?", kind: .text, expiresAt: nil),
            timeline: fake
        )
        vm.textInput = "answer"
        await vm.send()
        XCTAssertNotNil(vm.error)
        XCTAssertEqual(fake.sentText.count, 0)

        await vm.send()
        XCTAssertEqual(fake.sentText.count, 1, "post-error retry must reach the wire")
    }

    func test_send_closesSheet_onSuccess() async {
        var closed = false
        let vm = makeVM(
            event: AskUserEvent(prompt: "?", kind: .text, expiresAt: nil),
            onClose: { closed = true }
        )
        vm.textInput = "answer"
        await vm.send()
        XCTAssertTrue(closed)
    }

    func test_send_surfacesError_andKeepsSheetOpen() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let fake = FakeTimelineService()
        fake.nextSendError = Boom()
        var closed = false
        let vm = makeVM(
            event: AskUserEvent(prompt: "?", kind: .text, expiresAt: nil),
            timeline: fake,
            onClose: { closed = true }
        )
        vm.textInput = "answer"
        await vm.send()
        XCTAssertEqual(vm.error, "boom")
        XCTAssertFalse(closed)
        XCTAssertFalse(vm.isSending)
    }

    // MARK: - .buttonResponse channel (Matron X buttons contract)

    func test_send_buttonResponse_sendsSelectedValues_notLabels() async {
        let fake = FakeTimelineService()
        let opts = [
            AskUserEvent.Option(id: "a", label: "Send now", value: "interrupt"),
            AskUserEvent.Option(id: "b", label: "Cancel message 1", value: "cancel:0"),
        ]
        let vm = makeVM(
            event: AskUserEvent(
                prompt: "Queued messages",
                kind: .choice(options: opts, allowOther: false),
                expiresAt: nil,
                replyChannel: .buttonResponse
            ),
            timeline: fake
        )
        vm.selectedChoiceIDs = ["b"]
        await vm.send()
        XCTAssertEqual(fake.sentButtonResponses.count, 1)
        XCTAssertEqual(fake.sentButtonResponses[0].selectedValues, ["cancel:0"])
        XCTAssertEqual(fake.sentButtonResponses[0].inReplyTo, "$prompt-1")
        // Nothing on the text path — the answer goes out as a raw
        // button_response event only.
        XCTAssertEqual(fake.sentText, [])
    }

    func test_send_buttonResponse_isNoop_whenNothingSelected() async {
        let fake = FakeTimelineService()
        let opts = [AskUserEvent.Option(id: "a", label: "Yes", value: "yes")]
        let vm = makeVM(
            event: AskUserEvent(
                prompt: "?",
                kind: .choice(options: opts, allowOther: false),
                expiresAt: nil,
                replyChannel: .buttonResponse
            ),
            timeline: fake
        )
        await vm.send()
        XCTAssertEqual(fake.sentButtonResponses.count, 0)
    }

    // MARK: - Expiry

    func test_isExpired_isTrue_afterExpiresAt() {
        let vm = makeVM(
            event: AskUserEvent(prompt: "Q", kind: .text, expiresAt: Date.now.addingTimeInterval(-1))
        )
        XCTAssertTrue(vm.isExpired)
    }

    func test_send_isNoop_whenExpired() async {
        let fake = FakeTimelineService()
        let vm = makeVM(
            event: AskUserEvent(prompt: "Q", kind: .text, expiresAt: Date.now.addingTimeInterval(-1)),
            timeline: fake
        )
        vm.textInput = "answer"
        await vm.send()
        XCTAssertEqual(fake.sentText, [])
    }

    func test_awaitExpiry_callsOnExpire_afterExpiresAt() async {
        var didExpire = false
        let vm = makeVM(
            event: AskUserEvent(prompt: "Q?", kind: .text, expiresAt: Date.now.addingTimeInterval(0.1))
        )
        await vm.awaitExpiry(onExpire: { didExpire = true })
        XCTAssertTrue(didExpire)
        XCTAssertTrue(vm.isExpired)
    }

    func test_awaitExpiry_isNoop_whenNoExpiresAt() async {
        var didExpire = false
        let vm = makeVM(
            event: AskUserEvent(prompt: "Q?", kind: .text, expiresAt: nil)
        )
        await vm.awaitExpiry(onExpire: { didExpire = true })
        XCTAssertFalse(didExpire)
    }

    // MARK: - Editing a queued message

    private func queuedCard() -> AskUserEvent {
        AskUserEvent(prompt: "Send this queued message now, or cancel it?",
                     kind: .choice(options: [AskUserEvent.Option(id: "send", label: "⚡ Send now", value: "send"),
                                             AskUserEvent.Option(id: "cancel", label: "✕ Cancel", value: "cancel")],
                                   allowOther: false),
                     expiresAt: nil, replyChannel: .buttonResponse, queuedReleasePromptID: "pr_1",
                     queuedEdit: AskUserEvent.QueuedEdit(text: "fix the tests", holdSeconds: 600))
    }

    func test_edit_holdsFirst_thenOpensTheEditorWithTheQueuedText() async {
        let fake = FakeTimelineService()
        let vm = makeVM(event: queuedCard(), timeline: fake)
        XCTAssertTrue(vm.offersEdit)
        await vm.beginEdit()
        XCTAssertEqual(fake.sentQueuedEdits.map(\.choice), ["edit"])
        XCTAssertEqual(fake.sentQueuedEdits.first?.inReplyTo, "$prompt-1")
        XCTAssertTrue(vm.isEditing)
        XCTAssertEqual(vm.editText, "fix the tests")
    }

    func test_edit_thatCantReachTheJournal_keepsTheEditorClosed() async {
        let fake = FakeTimelineService()
        fake.nextSendError = NSError(domain: "test", code: 1)
        let vm = makeVM(event: queuedCard(), timeline: fake)
        await vm.beginEdit()
        XCTAssertFalse(vm.isEditing, "no editing while the message could still go out")
        XCTAssertNotNil(vm.editError)
    }

    func test_save_sendsTheEditedText_andRetiresTheCard() async {
        let fake = FakeTimelineService()
        var closed = 0
        let vm = makeVM(event: queuedCard(), timeline: fake, onClose: { closed += 1 })
        await vm.beginEdit()
        vm.editText = "  fix the flaky tests  "
        await vm.saveEdit()
        XCTAssertEqual(fake.sentQueuedEdits.map(\.choice), ["edit", "edit_save"])
        XCTAssertEqual(fake.sentQueuedEdits.last?.text, "fix the flaky tests")
        XCTAssertFalse(vm.isEditing)
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(vm.offersEdit)
    }

    func test_save_ofUnchangedText_justReleasesTheHold() async {
        let fake = FakeTimelineService()
        let vm = makeVM(event: queuedCard(), timeline: fake)
        await vm.beginEdit()
        await vm.saveEdit()
        XCTAssertEqual(fake.sentQueuedEdits.map(\.choice), ["edit", "edit_cancel"])
        XCTAssertFalse(vm.isEditing)
    }

    func test_save_isRefusedForAnEmptyEdit() async {
        let fake = FakeTimelineService()
        let vm = makeVM(event: queuedCard(), timeline: fake)
        await vm.beginEdit()
        vm.editText = "   "
        XCTAssertFalse(vm.canSaveEdit)
        await vm.saveEdit()
        XCTAssertEqual(fake.sentQueuedEdits.map(\.choice), ["edit"])
        XCTAssertTrue(vm.isEditing)
    }

    func test_cancelEdit_releasesTheHold_withTheOriginalText() async {
        let fake = FakeTimelineService()
        let vm = makeVM(event: queuedCard(), timeline: fake)
        await vm.beginEdit()
        vm.editText = "something else"
        await vm.cancelEdit()
        XCTAssertEqual(fake.sentQueuedEdits.map(\.choice), ["edit", "edit_cancel"])
        XCTAssertNil(fake.sentQueuedEdits.last?.text)
        XCTAssertFalse(vm.isEditing)
        XCTAssertTrue(vm.offersEdit, "the card still offers Edit, Send now and Cancel")
    }

    func test_aCardWithoutQueuedEdit_offersNone() {
        let vm = makeVM(event: AskUserEvent(prompt: "Deploy?", kind: .text, expiresAt: nil))
        XCTAssertFalse(vm.offersEdit)
    }
}
