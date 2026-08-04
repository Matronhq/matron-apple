import SwiftUI
import MatronModels

/// Tappable strip pinned at the top of a large conversation nudging the
/// user to compact it. Tapping sends a bare `/compact` (the caller wires
/// `onCompact` to `ChatViewModel.sendCommand`). Mirrors
/// `ConnectionStatusBanner`'s offline state — full-width, leading-aligned,
/// opaque red with white content — so it reads as the same "the app needs
/// your attention" vocabulary; the Android client ships the equivalent
/// banner (`CompactContextBanner.kt`), and the two stay
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

    /// Visible copy — exposed for tests so the wording stays pinned. The
    /// token count and the action verb are separate pieces: the title may
    /// truncate on narrow phones, the trailing "Compact" action never does.
    static func title(tokens: Int) -> String {
        "Large conversation (\(UsageMetersFormat.compactTokens(tokens)))"
    }

    /// Trailing action label, rendered next to the compact glyph.
    static let actionTitle = "Compact"

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
                Text(Self.title(tokens: tokens))
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                // Same glyph as the Compact button beside the context
                // gauge, so the two affordances read as one action. The
                // action pair is fixedSize so a narrow phone truncates the
                // title, never the verb.
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.caption)
                    .foregroundStyle(.white)
                Text(Self.actionTitle)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Compact the conversation — sends /compact")
        .accessibilityLabel(Self.spokenLabel(tokens: tokens))
        .accessibilityIdentifier("chat.banner.compact")
    }
}
