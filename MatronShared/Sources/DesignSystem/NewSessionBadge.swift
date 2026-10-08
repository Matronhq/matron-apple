import SwiftUI

/// "New" marker on the trailing edge of a chat-list row: a session that
/// appeared without the user asking for it on this device (an agent, the
/// Coordinator or a routine started it) and that they have not opened yet.
/// It stands in for the old behaviour of opening such a session over
/// whatever the user was doing.
///
/// Tinted rather than filled, so it reads as quieter than `UnreadBadge`
/// and `NeedsYouBadge` beside it; same type size and vertical padding, so
/// a row is the same height with or without it.
public struct NewSessionBadge: View {
    public init() {}

    public var body: some View {
        Text("New")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .accessibilityLabel("New session")
    }
}
