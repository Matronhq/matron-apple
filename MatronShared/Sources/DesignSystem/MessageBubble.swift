import SwiftUI

/// Visual style of a message bubble. Bots render left-aligned on a white
/// bubble; "me" renders right-aligned on a light-cyan bubble — matron-web's
/// bubble layout (`.mx_EventTile[data-layout="bubble"]`), sitting on the
/// cream timeline gradient (`MatronTimelineBackground`).
public enum MessageAuthorStyle {
    case bot
    case me
}

/// Layout primitive for a single message in the chat timeline. Wraps any
/// content (`MarkdownText`, `AttachmentImage`, `AttachmentFile`, …) and
/// applies the bubble chrome appropriate to the author. Lives in
/// `MatronDesignSystem` so both iOS (`TimelineItemView`) and macOS
/// (`MacChatView`) consume the same primitive and the snapshot test
/// baselines guard a single source of truth.
///
/// `timestamp`, when supplied, renders as a subtle light-grey time tucked into
/// the bubble's bottom-right corner. The sender name is deliberately NOT shown
/// above messages — these are 1:1 chats with one bot, so the label was noise.
public struct MessageBubble<Content: View>: View {
    let style: MessageAuthorStyle
    let timestamp: Date?
    let content: () -> Content

    public init(
        style: MessageAuthorStyle,
        timestamp: Date? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.style = style
        self.timestamp = timestamp
        self.content = content
    }

    public var body: some View {
        HStack {
            // The me/bot spacers do the left/right alignment. The bot spacer
            // uses `minLength: 0` so a long bot message can extend to the same
            // `.padding(.horizontal)` margin on the right as it has on the left
            // (even margins) instead of being held ~32pt short of the right
            // edge. Short messages still hug left because the spacer stays
            // greedy. `me` keeps a real min so sent bubbles don't span the full
            // width.
            if style == .me { Spacer(minLength: 32) }
            // Content + timestamp sit side by side on the SAME line:
            // `.lastTextBaseline` drops the time onto the baseline of the
            // message's last line, so a short message reads inline
            // ("Hi  12:15") and a multi-line one tucks the time at the
            // bottom-right after the final line.
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                content()
                if let timestamp {
                    Text(timestamp, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        // Don't let the time wrap or get squeezed — the
                        // message text yields width to it instead.
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // matron-web bubble chrome: white for the bot, light cyan for
            // own messages, both with the web's soft 1px-drop shadow so
            // they lift off the cream timeline behind them. Corner radius
            // matches the web's `--cornerRadius: 6px` (slightly softened).
            .background(style == .me ? Color.matronBubbleMe : Color.matronBubbleBot)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .matronBubbleShadow, radius: 1, y: 1)
            if style == .bot { Spacer(minLength: 0) }
        }
        .padding(.horizontal)
    }
}
