import SwiftUI
import MatronModels

/// Tappable strip pinned at the top of a large conversation nudging the
/// user to compact it. Tapping sends a bare `/compact` (the caller wires
/// `onCompact` to `ChatViewModel.sendCommand`). Mirrors
/// `ConnectionStatusBanner` in shape — full-width, leading-aligned,
/// ultra-thin material — so it reads as the same "the app is telling you
/// something" vocabulary; the Android client ships the identical banner
/// (`CompactContextBanner.kt`), and the two stay copy- and
/// threshold-compatible.
public struct CompactContextBanner: View {
    /// Absolute context size (in tokens) past which the banner appears.
    /// Absolute, not a fraction of the model's window: the concern is
    /// cost/latency/recall at large sizes, which a 1M-window model shares.
    public static let tokenThreshold = 200_000

    /// Whether the banner should show for `context`. Nil (no status frame
    /// yet) and exactly-at-threshold do not show; strictly above does.
    public static func shouldShow(_ context: SessionStatus.Context?) -> Bool {
        guard let context else { return false }
        return context.tokens > tokenThreshold
    }

    /// Visible copy — exposed for tests so the wording stays pinned.
    static func title(tokens: Int) -> String {
        "Large conversation (\(UsageMetersFormat.compactTokens(tokens)) tokens) · Tap to compact"
    }

    /// VoiceOver copy: the abbreviated "265k" reads badly spoken, so the
    /// label swaps in `spokenTokens` ("265 thousand").
    static func spokenLabel(tokens: Int) -> String {
        "Large conversation, \(UsageMetersFormat.spokenTokens(tokens)) tokens, tap to compact"
    }

    private let tokens: Int
    private let onCompact: () -> Void

    public init(tokens: Int, onCompact: @escaping () -> Void) {
        self.tokens = tokens
        self.onCompact = onCompact
    }

    public var body: some View {
        Button(action: onCompact) {
            HStack(spacing: 8) {
                // Same glyph as the Compact button beside the context
                // gauge, so the two affordances read as one action.
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text(Self.title(tokens: tokens))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Compact the conversation — sends /compact")
        .accessibilityLabel(Self.spokenLabel(tokens: tokens))
        .accessibilityIdentifier("chat.banner.compact")
    }
}
