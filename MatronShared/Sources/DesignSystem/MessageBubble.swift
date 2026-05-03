import SwiftUI

/// Visual style of a message bubble. Bots render flat (no bubble background,
/// left-aligned, with a small caption above for the bot's display name);
/// "me" renders right-aligned with a subtle filled rounded rectangle so the
/// user can tell at a glance which messages they sent.
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
public struct MessageBubble<Content: View>: View {
    let style: MessageAuthorStyle
    let senderLabel: String?
    let content: () -> Content

    public init(
        style: MessageAuthorStyle,
        senderLabel: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.style = style
        self.senderLabel = senderLabel
        self.content = content
    }

    public var body: some View {
        HStack {
            if style == .me { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 4) {
                if let label = senderLabel, style == .bot {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
                content()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // `Color.matronCodeBg` is the cross-platform alias defined
                    // in MarkdownText.swift — `Color(.systemGray6)` is iOS-only
                    // and would break the Mac build.
                    .background(style == .me ? Color.matronCodeBg : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            if style == .bot { Spacer(minLength: 32) }
        }
        .padding(.horizontal)
    }
}
