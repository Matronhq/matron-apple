import SwiftUI

/// Visual style of a message bubble. Bots render flat (no bubble background,
/// left-aligned); "me" renders right-aligned with a subtle filled rounded
/// rectangle so the user can tell at a glance which messages they sent.
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
            // `Color.matronCodeBg` is the cross-platform alias defined
            // in MarkdownText.swift — `Color(.systemGray6)` is iOS-only
            // and would break the Mac build.
            .background(style == .me ? Color.matronCodeBg : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            if style == .bot { Spacer(minLength: 0) }
        }
        .padding(.horizontal)
    }
}
