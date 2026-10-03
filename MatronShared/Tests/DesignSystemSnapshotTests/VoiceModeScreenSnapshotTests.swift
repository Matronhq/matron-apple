import XCTest
import SwiftUI
@testable import MatronDesignSystem

final class VoiceModeScreenSnapshotTests: XCTestCase {
    private func screen(_ model: VoiceModeScreen.Model) -> some View {
        VoiceModeScreen(model: model, onTap: {}, onSend: {}, onAction: { _ in }, onEnd: {})
            .frame(width: 390, height: 760)
    }

    // MARK: Pure

    func testStateWords() {
        XCTAssertEqual(VoiceModeScreen.stateText(.listening, boxName: "bev"), "Listening")
        XCTAssertEqual(VoiceModeScreen.stateText(.working, boxName: "bev"), "bev is working")
        XCTAssertEqual(VoiceModeScreen.stateText(.working, boxName: nil), "The agent is working")
        XCTAssertEqual(VoiceModeScreen.stateText(.waiting, boxName: "bev"), "Tap to talk")
        XCTAssertEqual(VoiceModeScreen.stateText(.confirming, boxName: nil), "Say cancel to stop")
        // "Did you mean Go?" sends on "yes" only: it must not read as if
        // silence would send it.
        XCTAssertEqual(VoiceModeScreen.stateText(.asking, boxName: nil), "Say yes or no")
        XCTAssertEqual(VoiceModeScreen.tapHint(.asking), "Cancel")
        XCTAssertEqual(VoiceModeScreen.tapHint(.speaking), "Interrupt")
        XCTAssertEqual(VoiceModeScreen.tapHint(.waiting), "Talk")
        XCTAssertEqual(VoiceModeScreen.unsentText(1), "1 voice note waiting for a connection")
        XCTAssertEqual(VoiceModeScreen.unsentText(3), "3 voice notes waiting for a connection")
    }

    func testEveryPhaseHasItsOwnSymbol() {
        let phases = VoiceModeScreen.Model.Phase.allCases
        XCTAssertEqual(phases.count, 7)
        XCTAssertEqual(Set(phases.map(VoiceModeScreen.symbol)).count, phases.count)
    }

    func testButtonsCallBack() {
        var log: [String] = []
        let view = VoiceModeScreen(model: .init(title: "T", phase: .listening, labels: ["Go"]),
                                   onTap: { log.append("tap") }, onSend: { log.append("send") },
                                   onAction: { log.append($0) }, onEnd: { log.append("end") })
        view.onTap(); view.onSend(); view.onAction("Go"); view.onEnd()
        XCTAssertEqual(log, ["tap", "send", "Go", "end"])
    }

    // MARK: Snapshots

    func testListening() {
        assertVariants(of: screen(.init(title: "Auth refactor", boxName: "bev", phase: .listening)), named: "voice-listening")
    }

    func testSpeakingWithCaption() {
        assertVariants(of: screen(.init(title: "Auth refactor", boxName: "bev", phase: .speaking,
                                        caption: "The deploy finished. Shall I merge? I can go deeper if you like.")),
                       named: "voice-speaking")
    }

    func testAnItemWithTwoLabels() {
        assertVariants(of: screen(.init(title: "Promo", boxName: "pat", phase: .listening,
                                        caption: "A decision: Ship the promo page. Options: Go, Wait.",
                                        labels: ["Go", "Wait"])),
                       named: "voice-item-two-labels")
    }

    /// Five labels: four buttons; the fifth is spoken only.
    func testAtMostFourLabelButtons() {
        assertVariants(of: screen(.init(title: "Schema", phase: .waiting,
                                        labels: ["Postgres", "SQLite", "MySQL", "DynamoDB", "None of them"])),
                       named: "voice-four-buttons")
    }

    func testWorkingWithUnsentNotes() {
        assertVariants(of: screen(.init(title: "Auth refactor", boxName: "bev", phase: .working, unsentCount: 2)),
                       named: "voice-working-unsent")
    }

    func testAsking() {
        assertVariants(of: screen(.init(title: "Auth refactor", boxName: "bev", phase: .asking,
                                        caption: "Did you mean Allow once?",
                                        labels: ["Allow once", "Always allow Bash (session)", "Deny"])),
                       named: "voice-asking")
    }

    func testConfirming() {
        assertVariants(of: screen(.init(title: "Promo", boxName: "pat", phase: .confirming, caption: "Sending: Go.",
                                        labels: ["Go", "Wait"])),
                       named: "voice-confirming")
    }
}
