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
    /// Optional retry handler for own-messages whose send state is
    /// `.failed(reason:)`. Wired by `ChatView` to
    /// `viewModel.retrySend(itemID:)`. `nil` for previews / tests.
    var onRetry: ((String) -> Void)? = nil
    /// Image-attachment tap handler — receives the row's resolved
    /// `Image` (already in memory via `resolveImage`) so the parent
    /// can present the fullscreen viewer without a second fetch.
    /// `nil` keeps existing test sites compiling unchanged.
    var onTapImage: ((Image) -> Void)? = nil
    /// File-attachment tap handler — receives the `mxc://` URL plus
    /// the original filename so the parent can stage the bytes to a
    /// temp file and present `ShareLink` (iOS) / `NSWorkspace.open`
    /// (Mac).
    var onTapFile: ((URL, String) -> Void)? = nil

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
        } else if item.isOwn && item.sendState != .sent {
            // Own-message with non-default send state: render the body
            // at reduced opacity (so the timeline visually distinguishes
            // pending / failed sends) plus a footer indicator carrying
            // the retry affordance. `.sent` is excluded explicitly so
            // the common case continues to bypass the wrapping VStack
            // (preserves the iOS snapshot test baselines).
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

    /// Maps the model's `TimelineItem.SendState` (in `MatronChat`) onto
    /// the design-system mirror enum (in `MatronDesignSystem`). The two
    /// types are kept separate so `MatronDesignSystem` doesn't have to
    /// depend on `MatronChat` for one row primitive — see
    /// `SendStateGlyph` for the full rationale.
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
                senderLabel: item.isOwn ? nil : displayName(for: item.sender)
            ) {
                MarkdownText(body)
            }
            // VoiceOver previously announced the body text without sender
            // context — `.combine` collapses the bubble + label into a
            // single element with an explicit `"<sender>: <body>"`
            // label so the listener knows who said it (QA finding #13).
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(for: item, body: body))

        case .image(let url, let caption, let sizeBytes):
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                senderLabel: item.isOwn ? nil : displayName(for: item.sender)
            ) {
                AttachmentImage(
                    image: resolvedImage(for: url),
                    placeholder: "Image",
                    caption: caption ?? sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                    // Forward tap to the parent only when we've got a
                    // resolved Image AND a registered handler. Tapping
                    // a still-loading placeholder is a no-op — opening
                    // the fullscreen viewer with no bytes would just
                    // show an empty black sheet.
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
                senderLabel: item.isOwn ? nil : displayName(for: item.sender)
            ) {
                AttachmentFile(
                    filename: filename,
                    sizeBytes: sizeBytes,
                    // Tap handler — only fires if we have both a URL
                    // and a registered handler. Without the URL there's
                    // nothing to fetch (`.file(url: nil, …)` is a
                    // theoretical state but possible per the model).
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

    /// Composes the accessibility label for a row. "Me" rather than the
    /// raw matrix ID so VoiceOver doesn't leak the user's full handle on
    /// every own-message read-out (QA finding #13).
    static func accessibilityLabel(for item: TimelineItem, body: String) -> String {
        let senderName = item.isOwn ? "Me" : displayName(for: item.sender)
        return "\(senderName): \(body)"
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
