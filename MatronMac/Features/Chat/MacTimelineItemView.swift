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
    /// Optional retry handler for own-messages whose send state is
    /// `.failed(reason:)`. Mirrors the iOS surface — wired by
    /// `MacChatView` to `viewModel.retrySend(itemID:)`.
    var onRetry: ((String) -> Void)? = nil
    /// Image-attachment tap handler — mirrors the iOS surface.
    var onTapImage: ((Image) -> Void)? = nil
    /// File-attachment tap handler — mirrors the iOS surface.
    /// `MacChatView` wires this through to a temp-file write +
    /// `NSWorkspace.shared.open(_:)`.
    var onTapFile: ((URL, String) -> Void)? = nil

    var body: some View {
        // See iOS `TimelineItemView.body` — `shouldRender` is dead
        // code in the body because `ChatViewModel.rows` filters
        // hidden items BEFORE the ForEach. Kept as a static helper
        // for `MacTimelineItemViewTests` to exercise the contract.
        if item.isOwn && item.sendState != .sent {
            // Own-message with non-default send state — see iOS
            // `TimelineItemView` for the full rationale. `.sent`
            // bypasses the wrapping VStack so the common case keeps
            // the existing layout untouched.
            VStack(alignment: .trailing, spacing: 2) {
                renderedBody
                    .opacity(item.sendState == .sending ? 0.7 : 1.0)
                SendStateIndicator(
                    state: Self.sendStateGlyph(for: item.sendState),
                    onRetry: onRetry.map { handler in { handler(item.id) } }
                )
                .padding(.horizontal)
            }
        } else {
            renderedBody
        }
    }

    /// Mac mirror of `TimelineItemView.sendStateGlyph(for:)` — see
    /// the iOS doc-comment for why this stays inline.
    static func sendStateGlyph(for state: TimelineItem.SendState) -> SendStateGlyph {
        switch state {
        case .sent: return .sent
        case .sending: return .sending
        case .failed(let reason): return .failed(reason: reason)
        }
    }

    @ViewBuilder
    private var renderedBody: some View {
        switch item.kind {
        case .text(let body, _):
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                senderLabel: item.isOwn ? nil : Self.displayName(for: item.sender)
            ) {
                MarkdownText(body)
            }
            // Mac VoiceOver mirror of the iOS accessibility wiring — see
            // `TimelineItemView.accessibilityLabel(for:body:)` (QA finding #13).
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(for: item, body: body))

        case .image(let url, let caption, let sizeBytes):
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                senderLabel: item.isOwn ? nil : Self.displayName(for: item.sender)
            ) {
                AttachmentImage(
                    image: resolvedImage(for: url),
                    placeholder: "Image",
                    caption: caption ?? sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                    // Tap forwards to the parent only when the bytes
                    // have already resolved AND a handler is wired.
                    // Tapping a still-loading placeholder is a no-op
                    // so the fullscreen viewer doesn't open with an
                    // empty `Image`.
                    onTap: {
                        if let img = resolvedImage(for: url),
                           let onTapImage {
                            onTapImage(img)
                        }
                    }
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(for: item, body: caption ?? "Image attachment"))

        case .file(let url, let filename, let sizeBytes):
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                senderLabel: item.isOwn ? nil : Self.displayName(for: item.sender)
            ) {
                AttachmentFile(
                    filename: filename,
                    sizeBytes: sizeBytes,
                    onTap: {
                        if let url, let onTapFile {
                            onTapFile(url, filename)
                        }
                    }
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(for: item, body: "File attachment: \(filename)"))

        case .stateChange(let text):
            HStack {
                Spacer()
                Text(text).font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)

        case .unknown(let eventType):
            // `m.room.encrypted` is the SDK's `unableToDecrypt` mapped
            // through; the SDK retries decryption as keys arrive and
            // replaces the row via a `.set` diff. Friendlier than the
            // raw "[unsupported event]" generic fallback.
            HStack {
                Spacer()
                if eventType == "m.room.encrypted" {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    Text("Encrypted message — waiting for key")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("[unsupported event: \(eventType)]")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    /// Mac mirror of `TimelineItemView.shouldRender(_:)`. Hides ALL
    /// stateChange rows — see iOS for the full rationale (bot-first
    /// chats don't want "Room state changed" / membership / profile
    /// noise; Phase 7 polish can bring back a metadata-events toggle).
    static func shouldRender(_ item: TimelineItem) -> Bool {
        if case .stateChange = item.kind {
            return false
        }
        return true
    }

    /// Phase 2 placeholder for member display names — strips the leading
    /// `@` sigil and returns the local part. Mirrors the iOS surface
    /// (`TimelineItemView.displayName(for:)`).
    static func displayName(for senderID: String) -> String {
        let withoutSigil = senderID.hasPrefix("@") ? String(senderID.dropFirst()) : senderID
        return withoutSigil.split(separator: ":").first.map(String.init) ?? senderID
    }

    /// Mac mirror of `TimelineItemView.accessibilityLabel(for:body:)` —
    /// see iOS for the rationale (QA finding #13).
    static func accessibilityLabel(for item: TimelineItem, body: String) -> String {
        let senderName = item.isOwn ? "Me" : displayName(for: item.sender)
        return "\(senderName): \(body)"
    }

    private func resolvedImage(for url: URL?) -> Image? {
        guard let url, let resolveImage else { return nil }
        return resolveImage(url)
    }
}
