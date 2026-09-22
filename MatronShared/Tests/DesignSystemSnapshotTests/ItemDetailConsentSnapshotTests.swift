import SwiftUI
import XCTest
import MatronEvents
import MatronModels
@testable import MatronDesignSystem

/// The spawn consent card inside item detail (item #2318). Three renderings
/// a user meets: the full card, answerable; the answer controls alone, for
/// an ask whose card event has not reached this device; and a started ask
/// offering to open the child's room.
@MainActor
final class ItemDetailConsentSnapshotTests: XCTestCase {
    private static let request = AgentSpawnRequest(
        requestID: "spawn-1", fromDeviceID: 4, fromName: "greg",
        fromConvoID: "c1", fromConvoTitle: "consent deploy",
        targetDeviceID: 9, targetName: "dan-mac",
        workdir: "/Users/dan/Dev/matron-apple", task: "Deploy the journal, then start #2318.",
        topic: "consent items")

    private static func item(state: ItemState = .open) -> TrackerItem {
        TrackerItem(id: "it_1", num: 2366, kind: .question, state: state, resolution: state == .closed ? .decided : nil,
                    awaiting: state == .open ? .user : nil, title: "Approve spawn on dan-mac — consent items",
                    body: "**greg** asks to start a new agent session on **dan-mac**.\n\n- **Box:** dan-mac\n- **Directory:** `/Users/dan/Dev/matron-apple`",
                    labels: ["consent"], links: [TrackerLink(url: "matron://consent/spawn/spawn-1", title: "Spawn request spawn-1")],
                    originConvoID: "c1", createdAt: .init(timeIntervalSince1970: 1_770_000_000), updatedAt: .init(timeIntervalSince1970: 1_770_000_000))
    }

    private func view(_ item: TrackerItem, consent: ItemSpawnConsent, comments: [TrackerComment] = []) -> some View {
        let model = ItemDetailView.Model(item: item, comments: comments, pending: [], originTitle: "consent deploy",
                                         availableResolutions: [.cancelled], isBusy: false, spawnConsent: consent)
        return ItemDetailView(model: model, draft: .constant(""), image: { _ in nil },
                              onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                              onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                              now: Date(timeIntervalSince1970: 1_770_000_600),
                              onAnswerSpawn: { _ in }, onOpenRoom: { _ in })
            .frame(width: 380, height: 760)
    }

    func testSpawnConsentAnswerable() {
        let consent = ItemSpawnConsent(requestID: "spawn-1", request: Self.request, state: .idle)
        assertVariants(of: view(Self.item(), consent: consent), named: "ItemDetail_spawnConsent_idle")
    }

    func testSpawnConsentWithoutTheCardEvent() {
        let consent = ItemSpawnConsent(requestID: "spawn-1", request: nil, state: .idle)
        assertVariants(of: view(Self.item(), consent: consent), named: "ItemDetail_spawnConsent_controlsOnly")
    }

    func testSpawnConsentStarted() {
        let outcome = SpawnOutcome(requestID: "spawn-1", outcome: "started", roomID: "room-7")
        let status = TrackerComment(id: "s", itemID: "it_1", author: .user, kind: .status, body: "Approved — the session started on dan-mac.",
                                    statusFrom: .init(state: .open, resolution: nil, awaiting: .user),
                                    statusTo: .init(state: .closed, resolution: .decided, awaiting: nil),
                                    createdAt: .init(timeIntervalSince1970: 1_770_000_300))
        let consent = ItemSpawnConsent(requestID: "spawn-1", request: Self.request, state: .resolved(outcome))
        assertVariants(of: view(Self.item(state: .closed), consent: consent, comments: [status]), named: "ItemDetail_spawnConsent_started")
    }
}
