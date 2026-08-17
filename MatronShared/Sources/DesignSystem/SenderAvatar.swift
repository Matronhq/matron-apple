import SwiftUI

/// Small tinted-circle avatar for a non-own message, shown beside its
/// bubble in rooms with ≥2 distinct senders (agent-chat rooms like
/// "dan-mac ↔ dev-2") — see `ChatViewModel.hasMultipleSenders`. 1:1 chats
/// never construct this; every non-own bubble there already reads as
/// "the bot", so a per-message avatar would just be noise.
///
/// Colour comes from `BoxChip.tint(for:)` — the same deterministic
/// name→hue mapping the box chip uses — so a sender's avatar matches its
/// box's colour in the chat list. No avatar images: initials + colour
/// only (spec, 2026-08-13).
///
/// Initials foreground comes from `BoxChip.contrastingForeground(for:)`,
/// not a hardcoded `.white` — the raw (full-opacity) fill spans light
/// hues (green/orange/cyan/mint) where white text falls well short of
/// WCAG AA at this font size; see that function's doc for why it picks
/// per-hue rather than reusing `BoxChip`'s pale-fill `textTint`.
public struct SenderAvatar: View {
    let name: String

    /// ~24pt per spec — small enough to sit beside a bubble without
    /// competing with it, big enough for two initials to stay legible.
    static let diameter: CGFloat = 24

    public init(_ name: String) {
        self.name = name
    }

    public var body: some View {
        Text(Self.initials(for: name))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(BoxChip.contrastingForeground(for: name))
            .frame(width: Self.diameter, height: Self.diameter)
            .background(BoxChip.tint(for: name), in: Circle())
            // The sender is already spoken in the bubble's own
            // accessibility label (`TimelineItemView.accessibilityLabel`)
            // — exposing the avatar too would double-announce it.
            .accessibilityHidden(true)
    }

    /// First letter of each name segment, uppercased, capped at two
    /// characters — digits count as a segment (`dev-2` → "D2", so
    /// `dev-2`/`dev-3`/`dev-6` stay visually distinct). Segments split
    /// on the separators box/agent names actually use (`-`, `_`, space,
    /// `.`); a single-segment name (`mavis`) yields a single initial
    /// rather than padding to two. Pure and static so it's unit-testable
    /// without constructing the view.
    ///
    /// The two-character cap is applied AFTER uppercasing, not before:
    /// `uppercased()` can EXPAND a character (German `ß` → `"SS"`), so
    /// capping the letter count pre-uppercase doesn't bound the final
    /// string length — `"ß-a"` would uppercase its two capped letters
    /// ("ß", "a") to three displayed characters ("SSA") despite the
    /// `prefix(2)` above (CodeRabbit, PR #141).
    public static func initials(for name: String) -> String {
        let separators = CharacterSet(charactersIn: "-_. ")
        let segments = name.components(separatedBy: separators).filter { !$0.isEmpty }
        let letters = segments.prefix(2).compactMap { $0.first }
        return String(String(letters).uppercased().prefix(2))
    }
}
