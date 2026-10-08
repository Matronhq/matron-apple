import Foundation
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

    @Environment(\.colorScheme) private var colorScheme

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

    /// Alpha of the chip's fill — the tint washed over the app background.
    /// Shared with `BoxChipTests`' WCAG audit so the maths and the
    /// rendering can never disagree about what the text actually sits on.
    static let fillAlpha: Double = 0.18

    /// How far `textTint` pulls each hue toward black (light) / white
    /// (dark). At these fractions every palette entry clears WCAG AA
    /// (4.5:1) over the `fillAlpha` fill in both schemes — dark indigo is
    /// the closest call at ≈4.6:1, saved by the dark system variants being
    /// lighter than the light hues (Android, whose palette keeps the light
    /// values in dark theme, had to deepen its indigo to 0.35 —
    /// matron-android#38). The full measured table is pinned by
    /// `BoxChipTests.testTextTintClearsWCAG_AA_overChipFillForEveryPaletteEntry`.
    static let lightTextMixFraction: Double = 0.35
    static let darkTextMixFraction: Double = 0.3

    /// The raw system hues are accent colours tuned for white text ON them,
    /// not for being text — teal/cyan/mint captions on the pale fill land
    /// around 2:1 contrast. Pull the text toward the label colour (darker in
    /// light mode, lighter in dark) to clear readable contrast while keeping
    /// the hue. Pre-mix OS floors (macOS 14 / iOS 17) keep the raw tint.
    private var textTint: Color {
        Self.textTint(for: displayName, in: colorScheme)
    }

    /// Same adjustment as a static, for text OUTSIDE the chip that should
    /// carry the box's hue — e.g. the `A:bc` session tag ahead of titles.
    public static func textTint(for name: String, in colorScheme: ColorScheme) -> Color {
        let base = tint(for: name)
        guard #available(iOS 18.0, macOS 15.0, *) else { return base }
        return colorScheme == .dark
            ? base.mix(with: .white, by: darkTextMixFraction)
            : base.mix(with: .black, by: lightTextMixFraction)
    }

    /// Apple's documented light-mode sRGB for each `palette` entry, same
    /// order — used only by `contrastingForeground(for:)` below to pick a
    /// legible text colour; never rendered directly (the fill itself
    /// always comes from `palette`/`tint(for:)`, so light/dark adaptation
    /// of the fill is unaffected). Frozen alongside `palette` — if that
    /// array is ever reordered or extended, this one must move with it.
    static let paletteRGB: [(r: Double, g: Double, b: Double)] = [
        (0, 122, 255),    // .blue
        (52, 199, 89),    // .green
        (255, 149, 0),    // .orange
        (175, 82, 222),   // .purple
        (48, 176, 199),   // .teal
        (255, 45, 85),    // .pink
        (88, 86, 214),    // .indigo
        (162, 132, 94),   // .brown
        (50, 173, 230),   // .cyan
        (0, 199, 190),    // .mint
    ]

    /// WCAG relative luminance (linearized sRGB) of an 0–255 component
    /// triple. Standard formula, see
    /// https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
    static func relativeLuminance(_ rgb: (r: Double, g: Double, b: Double)) -> Double {
        func linear(_ channel255: Double) -> Double {
            let c = channel255 / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.r) + 0.7152 * linear(rgb.g) + 0.0722 * linear(rgb.b)
    }

    /// WCAG-legible foreground for text drawn directly on this box's RAW
    /// (full-opacity) fill — e.g. `SenderAvatar`'s initials circle.
    ///
    /// Distinct from `textTint` below: that answers "what colour reads
    /// well NEXT TO a PALE, ~18%-opacity capsule that's mostly the page
    /// background", so it's driven by the app's light/dark colorScheme.
    /// A solid avatar circle's background luminance is fixed by the hue
    /// ITSELF, not by colorScheme — green/orange/cyan/mint read as
    /// "light" regardless of appearance — so this picks whichever of
    /// `.white`/`.black` has the higher WCAG contrast ratio against the
    /// specific hue. Most of the palette lands well clear of AA's 4.5:1
    /// small-text threshold either way; `.blue`/`.purple`/`.indigo` are
    /// the close calls, resolved by picking the objectively higher
    /// ratio rather than eyeballing it. See
    /// `BoxChipTests.testContrastingForegroundClearsWCAG_AA_forEveryPaletteEntry`
    /// for the measured ratio per entry.
    public static func contrastingForeground(for name: String) -> Color {
        let luminance = relativeLuminance(paletteRGB[paletteIndex(for: name)])
        let contrastWithWhite = (1.0 + 0.05) / (luminance + 0.05)
        let contrastWithBlack = (luminance + 0.05) / (0.0 + 0.05)
        return contrastWithBlack > contrastWithWhite ? .black : .white
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
            .background(Self.tint(for: displayName).opacity(Self.fillAlpha), in: Capsule())
            .foregroundStyle(textTint)
            .accessibilityLabel("Agent box \(displayName)")
    }
}
