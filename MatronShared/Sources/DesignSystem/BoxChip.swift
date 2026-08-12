import SwiftUI

/// The agent box that owns a conversation, as a small capsule beside the
/// title. Shown only when the user has two or more boxes — the decision is
/// made upstream in `JournalChatService`, so this view just renders whatever
/// name it is handed.
///
/// Single-line and truncating by construction: chat rows have a fixed-height
/// invariant (see `ChatRowHeightTests`) and a wrapping chip would break it.
public struct BoxChip: View {
    let displayName: String
    let lineLimit = 1

    public init(_ name: String) {
        self.displayName = name
    }

    public var body: some View {
        Text(displayName)
            .font(.caption2.weight(.medium))
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Agent box \(displayName)")
    }
}
