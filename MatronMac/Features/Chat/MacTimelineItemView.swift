import SwiftUI
import MatronChat
import MatronEvents
import MatronModels
import MatronDesignSystem
import MatronViewModels

/// Mac-side mirror of `Matron/Features/Chat/Rendering/TimelineItemView`.
/// Body is byte-identical bar the missing `displayName` static helper
/// (iOS tests pin the iOS surface; Mac re-uses the same logic via a free
/// function inside this file). The send-state → glyph mapping is shared
/// across platforms via `SendStateGlyph.from(_:)` in
/// `MatronDesignSystem/StateBridges.swift`.
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
    /// Inline ask-user — mirrors the iOS surface.
    var askViewModel: ((String) -> AskUserSheetViewModel?)? = nil
    var isPromptAnswered: ((String) -> Bool)? = nil
    var answerSummary: ((String) -> String?)? = nil

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
                    state: SendStateGlyph.from(item.sendState),
                    onRetry: onRetry.map { handler in { handler(item.id) } }
                )
                .padding(.horizontal)
            }
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
                timestamp: item.timestamp
            ) {
                MarkdownText(body, theme: .matronMessage, lineSpacing: 4)
            }
            // Mac VoiceOver mirror of the iOS accessibility wiring — see
            // `TimelineItemView.accessibilityLabel(for:body:)` (QA finding #13).
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(for: item, body: body))

        case .image(let url, let caption, let sizeBytes):
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                timestamp: item.timestamp
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
                timestamp: item.timestamp
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

        case .toolCall(_, let evt):
            // Fills the width like a normal message bubble (Dan, 2026-07-14)
            // — the terminal-style result block wants the room.
            HStack {
                ToolCallCard(event: evt)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(for: item, body: "Tool call: \(evt.tool)"))

        case .diff(_, let evt):
            // File-edit diff snippet — bot-aligned, fills the width like a
            // normal message bubble (Dan, 2026-07-14).
            HStack {
                DiffCard(event: evt)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(
                for: item, body: DiffCard.accessibilitySummary(for: evt)))

        case .liveOutput(_, let evt):
            // Fills the width like a normal message bubble — terminal output
            // wants columns. Session from the shared store so LazyVStack row
            // recycling reattaches to accumulated output instead of replaying.
            HStack {
                LiveOutputCard(session: LiveOutputSessionStore.shared.session(for: evt),
                               eventTimestamp: item.timestamp)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)

        case .toolStreamLive(_, let command, let text, let headTruncated):
            // Ephemeral live tile (journal tool_stream) — fills the width
            // like the liveOutput tile.
            HStack {
                ToolStreamCard(command: command, text: text, headTruncated: headTruncated)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)

        case .askUser(let eventID, let evt):
            // Inline, non-blocking card (bot-aligned like .toolCall) — same as iOS.
            HStack {
                askCard(eventID: eventID, event: evt)
                    .frame(maxWidth: 360, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(for: item, body: "Question: \(evt.prompt)"))

        case .askUserAnswer:
            // `chat.matron.button_response` answers are bookkeeping for
            // `ChatViewModel.pendingAsk()`, never rendered — Matron X
            // hides them too (own and others'). The user's choice is
            // visible through the answered prompt UI instead.
            EmptyView()

        case .activityIndicator(let label):
            ActivityIndicatorRow(label: label)

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
        // Button-response answers are pendingAsk bookkeeping, never
        // visible — same as iOS `TimelineItemView.shouldRender`.
        if case .askUserAnswer = item.kind {
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

    /// Builds the inline ask-user card — Mac mirror of
    /// `TimelineItemView.askCard(eventID:event:)`.
    @ViewBuilder
    private func askCard(eventID: String, event: AskUserEvent) -> some View {
        if let askViewModel, let isPromptAnswered, let answerSummary,
           let vm = askViewModel(eventID) {
            MacAskUserCardHost(
                viewModel: vm,
                isAnswered: isPromptAnswered(eventID),
                answerSummary: answerSummary(eventID)
            )
        } else {
            AskUserCard(
                event: event, isAnswered: false, answerSummary: nil,
                textInput: .constant(""), selectedChoiceIDs: .constant([]),
                booleanAnswer: .constant(nil),
                isSending: false, isExpired: false, error: nil, onSend: {}
            )
        }
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

/// Mac mirror of `AskUserCardHost`: binds a cached `AskUserSheetViewModel` to the
/// shared `AskUserCard`. Separate `@Bindable` view because property wrappers
/// can't be declared inline in a `@ViewBuilder` switch.
private struct MacAskUserCardHost: View {
    @Bindable var viewModel: AskUserSheetViewModel
    let isAnswered: Bool
    let answerSummary: String?
    /// Mac mirror of `AskUserCardHost.expiryTick`: toggled when
    /// `expires_at` passes so the card re-renders into its expired
    /// state. `isExpired` is `Date.now`-derived, so nothing wakes the
    /// view at the deadline without this (bugbot "Expiry timer no longer
    /// scheduled").
    @State private var expiryTick = false

    var body: some View {
        AskUserCard(
            event: viewModel.event,
            isAnswered: isAnswered,
            answerSummary: answerSummary,
            textInput: $viewModel.textInput,
            selectedChoiceIDs: $viewModel.selectedChoiceIDs,
            booleanAnswer: $viewModel.booleanAnswer,
            isSending: viewModel.isSending,
            isExpired: viewModel.isExpired,
            error: viewModel.error,
            onSend: { Task { await viewModel.send() } }
        )
        .task(id: viewModel.promptEventID) {
            await viewModel.awaitExpiry { expiryTick.toggle() }
        }
    }
}
