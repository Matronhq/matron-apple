import SwiftUI

/// Settled-empty placeholder for the chat timeline. Shown only after
/// the timeline has definitively yielded an empty snapshot — never
/// while we're still waiting for the first snapshot to arrive,
/// otherwise a slow first sync would flash this on every chat open.
///
/// Uses `ContentUnavailableView` so the layout, typography, and
/// VoiceOver semantics match the platform conventions for "this view
/// is intentionally empty" (the same primitive Mail uses for a chosen-
/// but-empty mailbox).
public struct EmptyChatPlaceholder: View {
    private let botName: String

    public init(botName: String) {
        self.botName = botName
    }

    public var body: some View {
        ContentUnavailableView {
            Label("No messages yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Say hi to \(botName) below.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No messages yet. Say hi to \(botName) below.")
    }
}
