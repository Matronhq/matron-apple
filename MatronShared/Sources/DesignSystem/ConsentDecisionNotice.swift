import SwiftUI
import MatronEvents

/// The `consent_decision` event's inline row: one quiet line, styled like
/// `CoordinatorNotice`, saying the Coordinator answered a consent card and
/// why.
public struct ConsentDecisionNotice: View {
    let decision: ConsentDecisionEvent

    public init(decision: ConsentDecisionEvent) { self.decision = decision }

    public var body: some View {
        Label(decision.text, systemImage: decision.decision == .approve ? "checkmark.shield" : "xmark.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .accessibilityElement(children: .combine)
    }
}
