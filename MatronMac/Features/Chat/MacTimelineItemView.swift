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
    /// Image-attachment tap handler — mirrors the iOS surface, plus the
    /// `mxc://` URL so the presenter can look up the bitmap's native
    /// pixel size for the fullscreen sheet.
    var onTapImage: ((URL, Image) -> Void)? = nil
    /// File-attachment tap handler — mirrors the iOS surface.
    /// `MacChatView` wires this through to a temp-file write +
    /// `NSWorkspace.shared.open(_:)`.
    var onTapFile: ((URL, String) -> Void)? = nil
    /// Whether a file attachment's blob download is in flight — drives
    /// the chip's spinner (`ChatViewModel.isDownloadingFile(_:)`).
    /// Read inside the row body so Observation invalidates the row when
    /// the flag flips. `nil` keeps previews/tests compiling.
    var isDownloadingFile: ((URL) -> Bool)? = nil
    /// Whether a file attachment's blob came back 404 (reaped server-side)
    /// — same closure pattern as `isDownloadingFile`, same Observation
    /// invalidation channel.
    var isMediaUnavailable: ((URL) -> Bool)? = nil
    /// Inline ask-user — mirrors the iOS surface.
    var askViewModel: ((String) -> AskUserSheetViewModel?)? = nil
    var isPromptAnswered: ((String) -> Bool)? = nil
    var answerSummary: ((String) -> String?)? = nil
    /// Agent-chat consent card — mirrors the iOS surface. `nil` renders the
    /// card read-only rather than offering buttons with nothing behind them.
    var agentChatState: ((String) -> AgentChatCardState)? = nil
    var onAnswerAgentChat: ((_ eventID: String, _ request: AgentChatRequest,
                             _ approve: Bool) -> Void)? = nil
    /// Same pair for spawn consent cards (`POST /agent-spawn/answer`).
    var agentSpawnState: ((String) -> AgentChatCardState)? = nil
    var onAnswerAgentSpawn: ((_ eventID: String, _ request: AgentSpawnRequest,
                              _ approve: Bool) -> Void)? = nil
    /// The conversation this row belongs to — tags live-output sessions in
    /// the shared store so chat teardown can suspend only its own sockets
    /// (`suspendSessions(in:)`). `nil` keeps previews/tests compiling.
    var convoID: String? = nil
    /// `ChatViewModel.hasMultipleSenders` — mirrors the iOS surface.
    /// Default `false` keeps every existing preview/test/1:1-chat call
    /// site rendering exactly as before (no avatar).
    var hasMultipleSenders: Bool = false

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
                timestamp: item.timestamp,
                sender: Self.avatarSender(for: item, hasMultipleSenders: hasMultipleSenders)
            ) {
                // Mac renders message bodies through a single selectable
                // NSTextView so a mouse drag can select across the whole
                // message — MarkdownUI's per-block Texts can't span a drag.
                // No streaming flag reaches this call site (a growing message
                // re-emits `.text` with a longer body), so we rely on
                // `MarkdownAttributed`'s source-keyed cache for cheap
                // re-conversion during streaming.
                SelectableMessageText(body)
            }
            // Mac VoiceOver mirror of the iOS accessibility wiring — see
            // `TimelineItemView.accessibilityLabel(for:body:)` (QA finding #13).
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(for: item, body: body))

        case .image(let url, let caption, let sizeBytes, let expired):
            // Tombstone flag (fresh syncs) OR a 404 discovered at fetch time
            // (already-synced clients never re-fetch the rewritten event).
            let isExpired = expired || (url.map { isMediaUnavailable?($0) ?? false } ?? false)
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                timestamp: item.timestamp,
                sender: Self.avatarSender(for: item, hasMultipleSenders: hasMultipleSenders)
            ) {
                // The caption renders OUTSIDE AttachmentImage as a normal
                // message body — it's the message, and the small gray
                // `.caption2` slot it used to squeeze through made it read
                // like metadata (Dan, 2026-08-02). The byte size only
                // shows when there's no caption, matching the old
                // caption-wins fallback.
                VStack(alignment: .leading, spacing: 6) {
                    AttachmentImage(
                        image: resolvedImage(for: url),
                        // A reaped image never resolves — say so instead of
                        // showing a forever-loading placeholder.
                        placeholder: isExpired ? "Image expired" : "Image",
                        meta: caption == nil
                            ? sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                            : nil,
                        // Tap forwards to the parent only when the bytes
                        // have already resolved AND a handler is wired.
                        // Tapping a still-loading placeholder is a no-op
                        // so the fullscreen viewer doesn't open with an
                        // empty `Image`.
                        onTap: {
                            if let url,
                               let img = resolvedImage(for: url),
                               let onTapImage {
                                onTapImage(url, img)
                            }
                        }
                    )
                    if let caption, !caption.isEmpty {
                        SelectableMessageText(caption)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            // Empty-string captions are hidden visually, so they must not
            // become a blank VoiceOver body either (bugbot, PR #88).
            .accessibilityLabel(Self.accessibilityLabel(
                for: item,
                body: {
                    // The caption must not swallow the expired state — a
                    // captioned expired image still needs VoiceOver to say
                    // so (Bugbot, PR #139).
                    let cap = caption.flatMap { $0.isEmpty ? nil : $0 }
                    let base = isExpired ? "Image attachment, expired" : "Image attachment"
                    return cap.map { isExpired ? "\(base). \($0)" : $0 } ?? base
                }()))

        case .file(let url, let filename, let caption, let sizeBytes, let expired):
            let isExpired = expired || (url.map { isMediaUnavailable?($0) ?? false } ?? false)
            let isLoading = !isExpired && (url.map { isDownloadingFile?($0) ?? false } ?? false)
            MessageBubble(
                style: item.isOwn ? .me : .bot,
                timestamp: item.timestamp,
                sender: Self.avatarSender(for: item, hasMultipleSenders: hasMultipleSenders)
            ) {
                // Caption outside the tappable chip, as a normal message
                // body — see the `.image` case.
                VStack(alignment: .leading, spacing: 6) {
                    AttachmentFile(
                        filename: filename,
                        sizeBytes: sizeBytes,
                        isLoading: isLoading,
                        isExpired: isExpired,
                        onTap: {
                            if let url, let onTapFile {
                                onTapFile(url, filename)
                            }
                        }
                    )
                    if let caption, !caption.isEmpty {
                        SelectableMessageText(caption)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            // The caption is visible message text now — VoiceOver must
            // speak it too, not just the filename (bugbot, PR #88). The
            // combined element replaces the chip's own children, so the
            // downloading state must be restated here or VoiceOver never
            // hears it (CodeRabbit, PR #138).
            .accessibilityLabel(Self.accessibilityLabel(
                for: item,
                body: {
                    let base: String
                    if isExpired {
                        base = "File attachment: \(filename), expired"
                    } else if isLoading {
                        base = "File attachment: \(filename), downloading"
                    } else {
                        base = "File attachment: \(filename)"
                    }
                    return caption.flatMap { $0.isEmpty ? nil : "\(base). \($0)" } ?? base
                }()))

        case .stateChange(let text):
            HStack {
                Spacer()
                Text(text).font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)

        case .toolCall(_, let evt):
            // Fills the width like a normal message bubble (Dan, 2026-07-14)
            // — the terminal-style result block wants the room. No wrapping
            // HStack + Spacer: a Spacer beside a maxWidth-.infinity frame
            // makes SwiftUI split the row 50/50 between the two flexible
            // children, which is exactly the "card stops at half the pane"
            // bug — the frame alone fills the row. The inner frame caps the
            // card at the same readable width as message bubbles; the outer
            // one anchors it to the left edge (bot side).
            ToolCallCard(event: evt)
                .frame(maxWidth: MessageBubbleMetrics.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(for: item, body: "Tool call: \(evt.tool)"))

        case .diff(_, let evt):
            // File-edit diff snippet — bot-aligned, fills the width like a
            // normal message bubble (Dan, 2026-07-14). No HStack + Spacer —
            // see the .toolCall comment (50/50 split bug).
            DiffCard(event: evt)
                .frame(maxWidth: MessageBubbleMetrics.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(
                for: item, body: DiffCard.accessibilitySummary(for: evt)))

        case .liveOutput(_, let evt):
            // Fills the width like a normal message bubble — terminal output
            // wants columns. Session from the shared store so LazyVStack row
            // recycling reattaches to accumulated output instead of replaying.
            LiveOutputCard(session: LiveOutputSessionStore.shared.session(for: evt, convoID: convoID),
                           eventTimestamp: item.timestamp)
                .frame(maxWidth: MessageBubbleMetrics.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

        case .toolStreamLive(_, let command, let text, let headTruncated):
            // Ephemeral live tile (journal tool_stream) — fills the width
            // like the liveOutput tile.
            ToolStreamCard(command: command, text: text, headTruncated: headTruncated)
                .frame(maxWidth: MessageBubbleMetrics.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
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

        case .agentChatRequest(let eventID, let request):
            // Same inline treatment as iOS: the decision belongs beside the
            // ask, and its answer leaves over HTTP, not into the timeline.
            HStack {
                AgentChatRequestCard(
                    request: request,
                    state: agentChatState?(eventID) ?? .expired,
                    onApprove: { onAnswerAgentChat?(eventID, request, true) },
                    onDeny: { onAnswerAgentChat?(eventID, request, false) }
                )
                .frame(maxWidth: 360, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Self.accessibilityLabel(
                for: item, body: "Agent chat request. \(request.headline)"))

        case .agentSpawnRequest(let eventID, let request):
            HStack {
                AgentSpawnRequestCard(
                    request: request,
                    state: agentSpawnState?(eventID) ?? .expired,
                    onApprove: { onAnswerAgentSpawn?(eventID, request, true) },
                    onDeny: { onAnswerAgentSpawn?(eventID, request, false) }
                )
                .frame(maxWidth: 360, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Self.accessibilityLabel(
                for: item, body: "New session request. \(request.headline)"))

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

    /// Sender name for `MessageBubble`'s `sender:` param, or `nil` for no
    /// avatar. Mirrors the iOS surface (`TimelineItemView.avatarSender(for:hasMultipleSenders:)`),
    /// including the `isEphemeralStreamingPlaceholder` exclusion — see
    /// that property's doc on `TimelineItem` for why a raw `hasMultipleSenders`
    /// check alone would draw a wrong-coloured avatar on the mid-turn
    /// streaming echo row (Cursor Bugbot on PR #141).
    static func avatarSender(for item: TimelineItem, hasMultipleSenders: Bool) -> String? {
        guard !item.isOwn, hasMultipleSenders, !item.isEphemeralStreamingPlaceholder else { return nil }
        return item.sender
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
