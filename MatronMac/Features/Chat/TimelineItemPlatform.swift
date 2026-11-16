import SwiftUI
import MatronDesignSystem

/// What `TimelineItemView` draws differently on the Mac: message text
/// through `SelectableMessageText`, and tool cards as wide as a message
/// bubble. The iOS app has its own `TimelineItemPlatform` with the same
/// members.
@MainActor
enum TimelineItemPlatform {
    /// A text message's body, in a single selectable `NSTextView` so a
    /// mouse drag can select across the whole message — MarkdownUI's
    /// per-block Texts can't span a drag. No streaming flag reaches here (a
    /// growing message re-emits `.text` with a longer body), so this relies
    /// on `MarkdownAttributed`'s source-keyed cache for cheap re-conversion
    /// during streaming.
    static func messageBody(_ body: String, itemID: String) -> some View {
        SelectableMessageText(body, itemID: itemID)
    }

    /// An image's or file's caption, drawn as a normal message body.
    static func caption(_ caption: String, itemID: String) -> some View {
        SelectableMessageText(caption, itemID: itemID)
    }

    /// A tool card, diff card or live-output tile, bot-aligned and as wide
    /// as a message bubble — terminal output wants the room. No wrapping
    /// HStack + Spacer: a Spacer beside a maxWidth-.infinity frame makes
    /// SwiftUI split the row 50/50 between the two flexible children, which
    /// is exactly the "card stops at half the pane" bug — the frame alone
    /// fills the row. The inner frame caps the card at the same readable
    /// width as message bubbles; the outer one anchors it to the left edge
    /// (bot side).
    static func toolCard<Card: View>(@ViewBuilder _ card: () -> Card) -> some View {
        card()
            .frame(maxWidth: MessageBubbleMetrics.maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }
}
