import SwiftUI
import MatronChat
import MatronModels
import MatronDesignSystem

/// Renders a single `TimelineItem` row. Text/image/file kinds are wrapped in
/// a `MessageBubble`; state changes and unknown events render as small
/// horizontal notices instead of full bubbles so they read as ambient
/// context (member joins, profile updates, unsupported event types).
///
/// Image attachments currently render with a placeholder — Task 12b adds a
/// `MediaService` and a `[URL: Image]` cache on `ChatViewModel` so the
/// resolved image can be passed in here.
struct TimelineItemView: View {
    let item: TimelineItem

    var body: some View {
        switch item.kind {
        case .text(let body, _):
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                senderLabel: item.isOwn ? nil : displayName(for: item.sender)
            ) {
                MarkdownText(body)
            }

        case .image(_, let caption, let sizeBytes):
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                senderLabel: item.isOwn ? nil : displayName(for: item.sender)
            ) {
                AttachmentImage(
                    image: nil,
                    placeholder: "Image",
                    caption: caption ?? sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                )
            }

        case .file(_, let filename, let sizeBytes):
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                senderLabel: item.isOwn ? nil : displayName(for: item.sender)
            ) {
                AttachmentFile(filename: filename, sizeBytes: sizeBytes)
            }

        case .stateChange(let text):
            HStack {
                Spacer()
                Text(text).font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)

        case .unknown(let eventType):
            HStack {
                Spacer()
                Text("[unsupported event: \(eventType)]")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    /// Phase 2 placeholder for member display names: take the local part of
    /// the Matrix ID. Phase 5+ can resolve from member events when those
    /// land in the SDK bridge.
    private func displayName(for senderID: String) -> String {
        senderID.split(separator: ":").first.map(String.init) ?? senderID
    }
}
