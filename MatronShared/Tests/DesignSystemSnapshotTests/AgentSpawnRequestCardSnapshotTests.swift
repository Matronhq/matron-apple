import XCTest
import SwiftUI
import SnapshotTesting
import MatronEvents
@testable import MatronDesignSystem

/// Visual baselines for `AgentSpawnRequestCard`. The three states a user
/// actually meets are covered: answerable (buttons), started (outcome line
/// plus the Open button into the child's room), and expired (nothing left
/// to press). No baseline existed for the agent-chat card and its
/// generic-fallback bug shipped invisibly — these pin the spawn card so a
/// rendering regression shows up as pixels.
final class AgentSpawnRequestCardSnapshotTests: XCTestCase {
    private static let request = AgentSpawnRequest(
        requestID: "spawn-1", fromDeviceID: 4, fromName: "dan-mac",
        fromConvoID: "69abc", fromConvoTitle: "69 text carry and fitting parity",
        targetDeviceID: 9, targetName: "dev-2",
        workdir: "~/yearbook-app", task: "Run the failing spec and report back.",
        topic: "ci triage")

    private func card(state: AgentSpawnCardState) -> some View {
        AgentSpawnRequestCard(
            request: Self.request, state: state, onApprove: {}, onDeny: {},
            onOpen: { _ in }
        )
        .frame(width: 360)
        .padding()
    }

    func test_idle() {
        assertVariants(of: card(state: .idle), named: "spawnCard_idle")
    }

    func test_started() {
        let outcome = SpawnOutcome(
            requestID: "spawn-1", outcome: "started", roomID: "room-7")
        assertVariants(of: card(state: .resolved(outcome)), named: "spawnCard_started")
    }

    func test_expired() {
        assertVariants(of: card(state: .resolved(.expired(requestID: "spawn-1"))),
                       named: "spawnCard_expired")
    }
}
