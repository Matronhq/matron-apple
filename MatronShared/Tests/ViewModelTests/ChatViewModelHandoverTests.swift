import XCTest
import MatronChat
import MatronEvents
import MatronJournal
@testable import MatronViewModels

private final class RecordingGrantAnswerer: GrantAnswering, @unchecked Sendable {
    var error: Error?
    private(set) var calls: [(grantID: String, approve: Bool, excludeMedia: [String], keepLevel: String?)] = []
    private let lock = NSLock()

    func answerGrant(grantID: String, approve: Bool, excludeMedia: [String], keepLevel: String?) async throws {
        lock.withLock { calls.append((grantID, approve, excludeMedia, keepLevel)) }
        if let error { throw error }
    }
}

private func handoverCard(_ direction: PersonConsentCard.Direction,
                          mirror: PersonConsentCard.Mirror = .unknown,
                          keepLevel: MissionHandoverDetails.KeepLevel = .read) -> PersonConsentCard {
    PersonConsentCard(kind: .missionHandover, direction: direction,
                      personName: direction == .outgoing ? "bob" : "alice", askID: "gr_9", level: "owner",
                      handover: MissionHandoverDetails(subjectTitle: "Cover editor", brief: "Where it stands.",
                                                       attachments: [.init(mediaID: "md_1", name: "proof.pdf"),
                                                                     .init(mediaID: "md_2", name: "cover.png")],
                                                       keepLevel: keepLevel),
                      mirror: mirror)
}

/// A hand-over card answers itself on `POST /grants/:id/answer`: the owner
/// approving with the files they unticked, or declining; the recipient
/// accepting or declining, never with files.
@MainActor
final class ChatViewModelHandoverTests: XCTestCase {
    private func make(_ answerer: RecordingGrantAnswerer? = RecordingGrantAnswerer())
        -> (ChatViewModel, RecordingGrantAnswerer?) {
        (ChatViewModel(roomID: #function, timeline: FakeTimelineService(), media: FakeMediaService(),
                       grantAnswering: answerer), answerer)
    }

    /// The files the owner unticked live in the view model, not the card:
    /// a timeline row is rebuilt on scroll and when the card is restated,
    /// and a rebuilt card must not tick them again.
    func test_untickedFilesOutliveTheCard() {
        let (vm, _) = make()
        XCTAssertEqual(vm.handoverExcludedMedia("11"), [])
        vm.setHandoverExcludedMedia("11", ["md_2"])
        XCTAssertEqual(vm.handoverExcludedMedia("11"), ["md_2"])
        XCTAssertEqual(vm.handoverExcludedMedia("12"), [])
        vm.setHandoverExcludedMedia("11", [])
        XCTAssertEqual(vm.handoverExcludedMedia("11"), [])
    }

    /// The keep-contributing switch is held the same way: a rebuilt card
    /// starts from what the owner last chose, not from the ask.
    func test_theKeepSwitchOutlivesTheCard() {
        let (vm, _) = make()
        XCTAssertNil(vm.handoverKeepContributing("11"))
        vm.setHandoverKeepContributing("11", true)
        XCTAssertEqual(vm.handoverKeepContributing("11"), true)
        XCTAssertNil(vm.handoverKeepContributing("12"))
        vm.setHandoverKeepContributing("11", false)
        XCTAssertEqual(vm.handoverKeepContributing("11"), false)
    }

    func test_theOwnersApproveAlwaysSaysWhatTheyKeep() async {
        let (vm, answerer) = make()
        await vm.answerHandover(eventID: "11", card: handoverCard(.outgoing), approve: true, keepContributing: true)
        XCTAssertEqual(answerer?.calls.last?.keepLevel, "contribute")

        let (vm2, answerer2) = make()
        await vm2.answerHandover(eventID: "11", card: handoverCard(.outgoing, keepLevel: .contribute),
                                 approve: true, keepContributing: false)
        XCTAssertEqual(answerer2?.calls.last?.keepLevel, "read")
    }

    func test_withNoSwitchValueTheOwnersApproveKeepsTheAsk() async {
        let (vm, answerer) = make()
        await vm.answerHandover(eventID: "11", card: handoverCard(.outgoing, keepLevel: .contribute), approve: true)
        XCTAssertEqual(answerer?.calls.last?.keepLevel, "contribute")

        let (vm2, answerer2) = make()
        await vm2.answerHandover(eventID: "11", card: handoverCard(.outgoing), approve: true)
        XCTAssertEqual(answerer2?.calls.last?.keepLevel, "read")
    }

    func test_aDeclineOrTheRecipientsAnswerSendsNoKeepLevel() async {
        let (vm, answerer) = make()
        await vm.answerHandover(eventID: "11", card: handoverCard(.outgoing), approve: false, keepContributing: true)
        XCTAssertNil(answerer?.calls.last?.keepLevel)

        let (vm2, answerer2) = make()
        await vm2.answerHandover(eventID: "12", card: handoverCard(.incoming, keepLevel: .contribute),
                                 approve: true, keepContributing: true)
        XCTAssertNil(answerer2?.calls.last?.keepLevel)
    }

    func test_theOwnersApproveLeavesTheUntickedFilesBehind() async {
        let (vm, answerer) = make()
        let card = handoverCard(.outgoing)
        XCTAssertEqual(vm.handoverState("11", card: card), .idle)
        await vm.answerHandover(eventID: "11", card: card, approve: true, excludeMedia: ["md_2"])
        XCTAssertEqual(answerer?.calls.count, 1)
        XCTAssertEqual(answerer?.calls.first?.grantID, "gr_9")
        XCTAssertEqual(answerer?.calls.first?.approve, true)
        XCTAssertEqual(answerer?.calls.first?.excludeMedia, ["md_2"])
        XCTAssertEqual(vm.handoverState("11", card: card), .answered(approved: true))
    }

    func test_aDeclineSendsNoFiles() async {
        let (vm, answerer) = make()
        await vm.answerHandover(eventID: "11", card: handoverCard(.outgoing), approve: false, excludeMedia: ["md_2"])
        XCTAssertEqual(answerer?.calls.first?.approve, false)
        XCTAssertEqual(answerer?.calls.first?.excludeMedia, [])
    }

    func test_theRecipientsAcceptNeverCarriesFiles() async {
        let (vm, answerer) = make()
        let card = handoverCard(.incoming)
        await vm.answerHandover(eventID: "12", card: card, approve: true, excludeMedia: ["md_1"])
        XCTAssertEqual(answerer?.calls.first?.approve, true)
        XCTAssertEqual(answerer?.calls.first?.excludeMedia, [])
        XCTAssertEqual(vm.handoverState("12", card: card), .answered(approved: true))
    }

    func test_anAnsweredCardIsNotAnsweredTwice() async {
        let (vm, answerer) = make()
        let card = handoverCard(.incoming)
        await vm.answerHandover(eventID: "12", card: card, approve: true)
        await vm.answerHandover(eventID: "12", card: card, approve: false)
        XCTAssertEqual(answerer?.calls.count, 1)
    }

    func test_aConflictSettlesTheCard() async {
        let answerer = RecordingGrantAnswerer()
        answerer.error = JournalAPIError.conflict
        let (vm, _) = make(answerer)
        let card = handoverCard(.incoming)
        await vm.answerHandover(eventID: "12", card: card, approve: true)
        XCTAssertEqual(vm.handoverState("12", card: card), .settled)
    }

    func test_aFailureKeepsTheCardAnswerable() async {
        let answerer = RecordingGrantAnswerer()
        answerer.error = URLError(.notConnectedToInternet)
        let (vm, _) = make(answerer)
        let card = handoverCard(.outgoing)
        await vm.answerHandover(eventID: "11", card: card, approve: true)
        guard case .failed = vm.handoverState("11", card: card) else {
            return XCTFail("expected .failed, got \(vm.handoverState("11", card: card))")
        }
        XCTAssertTrue(vm.handoverState("11", card: card).isAnswerable)
        answerer.error = nil
        await vm.answerHandover(eventID: "11", card: card, approve: true)
        XCTAssertEqual(vm.handoverState("11", card: card), .answered(approved: true))
    }

    func test_aClosedMirrorSettlesTheCard() async {
        let (vm, answerer) = make()
        let card = handoverCard(.incoming, mirror: .closed(itemID: "it_1"))
        XCTAssertEqual(vm.handoverState("12", card: card), .settled)
        await vm.answerHandover(eventID: "12", card: card, approve: true)
        XCTAssertEqual(answerer?.calls.count, 0)
    }

    func test_withNoAnswererOrNoGrantTheCardIsSettled() {
        let (vm, _) = make(nil)
        XCTAssertEqual(vm.handoverState("11", card: handoverCard(.outgoing)), .settled)
        let (wired, _) = make()
        let noGrant = PersonConsentCard(kind: .missionHandover, direction: .incoming, personName: "alice", askID: nil,
                                        handover: MissionHandoverDetails())
        XCTAssertEqual(wired.handoverState("11", card: noGrant), .settled)
    }
}
