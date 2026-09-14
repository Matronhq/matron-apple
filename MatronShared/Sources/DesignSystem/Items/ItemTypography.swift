import SwiftUI
import MarkdownUI

/// Type and measure for the tracker item reading surface (`ItemDetailView`
/// and `ItemCommentComposer`). One place for the numbers so the body card,
/// the comment cards, the pending rows and the composer cannot drift apart
/// (tracker #66, #72).
///
/// The item thread is a reading surface, not a chat: a filed question is
/// often several paragraphs, read once on a wide Mac window. So it gets a
/// size a step above the chat message scale, more generous leading, and a
/// capped, centred column instead of stretching across the window.
public enum ItemTypography {
    #if os(macOS)
    /// ×1.40 ⇒ ≈18pt on macOS (13pt base). Well above the Mac chat
    /// timeline's 14.3pt (`MarkdownAttributed.baseFontSize`) — the chat
    /// scale was walked down for a stream of short turns; a thread of
    /// paragraphs wants a reading face. (The ×1.25 and first ×1.40 steps
    /// on 2026-09-14 never rendered — see `Theme.matronItem` — so 18pt is
    /// the first size Dan actually sees above the 13pt base.)
    static let bodyScale: CGFloat = 1.40
    /// Extra leading between wrapped lines, on top of the font's own.
    public static let lineSpacing: CGFloat = 5
    /// The item title, a step above the body: 22pt semibold on the Mac.
    public static let titleFont: Font = .title.weight(.semibold)
    /// Author / date captions on a card — 12pt/11pt, so they don't read
    /// as footnotes beside an 18pt body.
    public static let captionFont: Font = .callout
    public static let captionDetailFont: Font = .subheadline
    #else
    /// ×1.18 ⇒ ≈20pt on iOS/iPad (17pt base) — the size `MessageTextScale`
    /// intends for chat messages there. (Chat bodies through MarkdownUI
    /// actually render at the 17pt base today because their `.em` scale is
    /// ignored — see `Theme.matronItem`; that is a separate fix.)
    static let bodyScale: CGFloat = MessageTextScale.scale
    public static let lineSpacing: CGFloat = 3
    public static let titleFont: Font = .title2.weight(.semibold)
    public static let captionFont: Font = .caption
    public static let captionDetailFont: Font = .caption2
    #endif

    /// Gap after each markdown paragraph inside a body — a real paragraph
    /// break, not just a wrapped line, so multi-paragraph items read as
    /// prose rather than a wall.
    static let paragraphSpacing: CGFloat = 14

    /// Maximum width of the thread column. At ≈16pt this is roughly
    /// 70–75 characters per line (the classic 65–75 measure); wider than
    /// this the eye loses the line start on the way back. The column is
    /// centred in the detail view when there is more room than this.
    public static let measure: CGFloat = 640

    /// Vertical gap between thread rows (header, body card, comments).
    static let threadSpacing: CGFloat = 18
    /// Inner padding of a body/comment card.
    static let cardPadding: CGFloat = 14

    /// MarkdownUI's base body size — `FontProperties.defaultSize`, the
    /// point size its `.em` font sizes resolve against before Dynamic
    /// Type scaling. Plain `Text` beside a markdown body must start from
    /// the same base (and scale the same way, via `@ScaledMetric
    /// (relativeTo: .body)` on the view) or the two drift apart at any
    /// non-default text size.
    static let baseSize: CGFloat = {
        #if os(macOS)
        return 13
        #else
        return 17
        #endif
    }()
}

public extension Theme {
    /// Item-thread variant of `.matron`: the `ItemTypography` body size
    /// plus a real paragraph gap. Pair with `ItemTypography.lineSpacing`
    /// on `MarkdownText` for the leading.
    ///
    /// The size is given in POINTS, never `.em`. MarkdownUI 2.x applies
    /// `theme.text` on the outside and then re-applies its own base size
    /// as an absolute `FontSize` just inside it (`ScaledFontSizeModifier`,
    /// `Markdown.body`), and an absolute `FontSize` resets the relative
    /// `scale` to 1 — so `FontSize(.em(x))` in a theme's `.text` style is
    /// silently ignored. (That is why `Theme.matronMessage`'s `.em` scale
    /// never took effect either.) An absolute size survives: the modifier
    /// reads it back and re-applies it through a `@ScaledMetric
    /// (relativeTo: .body)`, so Dynamic Type still scales it on iOS.
    /// `ItemTypographyRenderTests` pins that the rendered text is
    /// actually larger than the base.
    static let matronItem: Theme = matron
        .text {
            FontFamily(.system(.default))
            ForegroundColor(.primary)
            FontSize(ItemTypography.baseSize * ItemTypography.bodyScale)
        }
        // Symmetric on purpose: MarkdownUI spaces neighbouring blocks by
        // the larger of the two facing margins, and no other block style
        // in `.matron` sets one, so a bottom-only margin would leave a
        // paragraph flush against the code fence or list above it while
        // gapped from the one below. `max` means paragraph→paragraph is
        // still one gap, not two.
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: ItemTypography.paragraphSpacing, bottom: ItemTypography.paragraphSpacing)
        }
}
