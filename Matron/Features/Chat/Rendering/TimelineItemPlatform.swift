import SwiftUI
import MatronDesignSystem

/// What `TimelineItemView` draws differently on iPhone and iPad: message
/// text through `MarkdownText`, and tool cards capped at 480 pt. The Mac
/// app has its own `TimelineItemPlatform` with the same members.
@MainActor
enum TimelineItemPlatform {
    /// A text message's body. A streaming overlay row ("eph:<ref>")
    /// re-renders with a longer body on every commit — caching those parses
    /// would just churn the markdown memo and evict real messages.
    static func messageBody(_ body: String, itemID: String) -> some View {
        MarkdownText(body, theme: .matronMessage, lineSpacing: 4,
                     cacheParsed: !itemID.hasPrefix("eph:"))
    }

    /// An image's or file's caption, drawn as a normal message body.
    static func caption(_ caption: String, itemID: String) -> some View {
        MarkdownText(caption, theme: .matronMessage, lineSpacing: 4)
    }

    /// A tool card, diff card or live-output tile, bot-aligned. Capped at
    /// 480 pt: command output wants columns, and a card narrower than the
    /// message bubbles around it read as cramped. The card hugs its
    /// content, so small ones stay small.
    static func toolCard<Card: View>(@ViewBuilder _ card: () -> Card) -> some View {
        HStack {
            card()
                .frame(maxWidth: 480, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
    }
}
