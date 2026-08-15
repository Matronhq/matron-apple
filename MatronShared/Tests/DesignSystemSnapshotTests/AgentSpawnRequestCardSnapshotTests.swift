import XCTest
import SwiftUI
import SnapshotTesting
import MatronEvents
@testable import MatronDesignSystem

/// Visual baselines for `AgentSpawnRequestCard`. The three states a user
/// actually meets are covered: answerable (buttons), answered (verdict
/// line), and expired (nothing left to press). No baseline existed for the
/// agent-chat card and its generic-fallback bug shipped invisibly — these
/// pin the spawn card so a rendering regression shows up as pixels.
final class AgentSpawnRequestCardSnapshotTests: XCTestCase {
    private static let request = AgentSpawnRequest(
        requestID: "spawn-1", fromDeviceID: 4, fromName: "dan-mac",
        targetDeviceID: 9, targetName: "dev-2",
        fromConvoID: "69abc", fromConvoTitle: "69 text carry and fitting parity",
        workdir: "~/yearbook-app", task: "Run the failing spec and report back.",
        topic: "ci triage")

    private func card(state: AgentChatCardState) -> some View {
        AgentSpawnRequestCard(
            request: Self.request, state: state, onApprove: {}, onDeny: {}
        )
        .frame(width: 360)
        .padding()
    }

    func test_idle() {
        assertVariants(of: card(state: .idle), named: "spawnCard_idle")
    }

    func test_answered() {
        assertVariants(of: card(state: .answered(approved: true)), named: "spawnCard_approved")
    }

    func test_expired() {
        assertVariants(of: card(state: .expired), named: "spawnCard_expired")
    }
}
