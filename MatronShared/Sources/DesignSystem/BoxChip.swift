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

    /// Fixed hue palette. Order is frozen — reordering or inserting entries
    /// re-rolls every user's box colours (testPaletteIndexIsPinned pins it).
    /// System colours, so light/dark adaptation comes for free.
    static let palette: [Color] = [
        .blue, .green, .orange, .purple, .teal,
        .pink, .indigo, .brown, .cyan, .mint,
    ]

    /// Deterministic colour for a box name: same name → same colour on
    /// every platform, every launch (and portably on Android). Collisions
    /// between names are fine — the colour is an aid, the name is printed.
    public static func tint(for name: String) -> Color {
        palette[paletteIndex(for: name)]
    }

    /// FNV-1a (32-bit) over UTF-8, mod palette size. Explicitly not
    /// `Hashable` — Swift's hash seed changes per launch.
    static func paletteIndex(for name: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(palette.count))
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
