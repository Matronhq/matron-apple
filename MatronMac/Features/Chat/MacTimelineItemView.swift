import SwiftUI
import MatronChat
import MatronModels
import MatronDesignSystem

/// Mac-side mirror of `Matron/Features/Chat/Rendering/TimelineItemView`.
/// Body is byte-identical bar the missing `displayName` static helper
/// (iOS tests pin the iOS surface; Mac re-uses the same logic via a free
/// function inside this file). Duplicated rather than shared so
/// `MatronDesignSystem` doesn't have to depend on `MatronChat` /
/// `MatronModels` for one row primitive.
struct MacTimelineItemView: View {
    let item: TimelineItem
    /// Optional resolver for `mxc://` image URLs. `nil` keeps the legacy
    /// placeholder rendering for previews and tests that don't wire up a
    /// `ChatViewModel`.
    var resolveImage: ((URL) -> Image?)? = nil

    var body: some View {
        switch item.kind {
        case .text(let body, _):
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                senderLabel: item.isOwn ? nil : Self.displayName(for: item.sender)
            ) {
                MarkdownText(body)
            }

        case .image(let url, let caption, let sizeBytes):
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                senderLabel: item.isOwn ? nil : Self.displayName(for: item.sender)
            ) {
                AttachmentImage(
                    image: resolvedImage(for: url),
                    placeholder: "Image",
                    caption: caption ?? sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                )
            }

        case .file(_, let filename, let sizeBytes):
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                senderLabel: item.isOwn ? nil : Self.displayName(for: item.sender)
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

    /// Phase 2 placeholder for member display names — strips the leading
    /// `@` sigil and returns the local part. Mirrors the iOS surface
    /// (`TimelineItemView.displayName(for:)`).
    static func displayName(for senderID: String) -> String {
        let withoutSigil = senderID.hasPrefix("@") ? String(senderID.dropFirst()) : senderID
        return withoutSigil.split(separator: ":").first.map(String.init) ?? senderID
    }

    private func resolvedImage(for url: URL?) -> Image? {
        guard let url, let resolveImage else { return nil }
        return resolveImage(url)
    }
}
