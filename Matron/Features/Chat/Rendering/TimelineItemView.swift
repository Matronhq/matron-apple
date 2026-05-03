import SwiftUI
import MatronChat
import MatronModels
import MatronDesignSystem

/// Renders a single `TimelineItem` row. Text/image/file kinds are wrapped in
/// a `MessageBubble`; state changes and unknown events render as small
/// horizontal notices instead of full bubbles so they read as ambient
/// context (member joins, profile updates, unsupported event types).
///
/// Image attachments are resolved through the parent's `resolveImage`
/// closure (typically `ChatViewModel.image(for:)`). The closure returns
/// `nil` on first call (cache miss) and kicks off a background fetch;
/// once `ChatViewModel.resolvedImages` updates, SwiftUI re-evaluates the
/// row and the resolved `Image` is handed to `AttachmentImage`.
struct TimelineItemView: View {
    let item: TimelineItem
    /// Optional resolver for `mxc://` image URLs. `nil` keeps the legacy
    /// placeholder rendering for previews and tests that don't wire up a
    /// `ChatViewModel`. Production usage in `ChatView` always passes
    /// `viewModel.image(for:)`.
    var resolveImage: ((URL) -> Image?)? = nil

    var body: some View {
        if !Self.shouldRender(item) {
            // Round-5 bugbot finding #2: `TimelineServiceLive.mapVirtual`
            // collapses `dateDivider`, `readMarker`, and `timelineStart`
            // virtual items into `.stateChange(text: "")`. The
            // `.stateChange` branch below wraps the text in a padded
            // `HStack` with `Spacer`s, which renders as a visible 8pt
            // empty row for these placeholders. Phase 2 closeout takes
            // option (a) — render nothing for empty state-change text.
            // Phase 3+ can extend `TimelineItem.Kind` with proper
            // `.dateDivider` / `.readMarker` / `.timelineStart` cases and
            // give them real visual treatment without disturbing the
            // existing snapshot baselines.
            EmptyView()
        } else {
            renderedBody
        }
    }

    @ViewBuilder
    private var renderedBody: some View {
        switch item.kind {
        case .text(let body, _):
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                senderLabel: item.isOwn ? nil : displayName(for: item.sender)
            ) {
                MarkdownText(body)
            }

        case .image(let url, let caption, let sizeBytes):
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                senderLabel: item.isOwn ? nil : displayName(for: item.sender)
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

    /// Whether a `TimelineItem` should render at all. Returns `false` for
    /// `.stateChange(text: "")`, which `TimelineServiceLive.mapVirtual`
    /// emits for `dateDivider`, `readMarker`, and `timelineStart` virtual
    /// items — these have no Phase-2 visual treatment, and rendering an
    /// empty `.stateChange` produces a visible 8pt padded blank row. Phase
    /// 3+ can replace this with a `Kind`-level enum case + dedicated
    /// renderer; for now skipping them keeps the timeline tight without
    /// disturbing the existing snapshot baselines. `static internal` so
    /// `TimelineItemViewTests` can exercise the contract without rendering.
    static func shouldRender(_ item: TimelineItem) -> Bool {
        if case .stateChange(let text) = item.kind, text.isEmpty {
            return false
        }
        return true
    }

    /// Phase 2 placeholder for member display names: take the local part of
    /// the Matrix ID without the leading `@` sigil. Phase 5+ can resolve
    /// from member events when those land in the SDK bridge.
    /// `internal static` so unit tests in `MatronTests` can pin the
    /// formatting without instantiating the SwiftUI view.
    static func displayName(for senderID: String) -> String {
        let withoutSigil = senderID.hasPrefix("@") ? String(senderID.dropFirst()) : senderID
        return withoutSigil.split(separator: ":").first.map(String.init) ?? senderID
    }

    private func displayName(for senderID: String) -> String {
        Self.displayName(for: senderID)
    }

    /// Resolves an image URL via the injected `resolveImage` closure if
    /// present. Returns `nil` for previews/tests, which falls through to
    /// `AttachmentImage`'s placeholder rendering.
    private func resolvedImage(for url: URL?) -> Image? {
        guard let url, let resolveImage else { return nil }
        return resolveImage(url)
    }
}
