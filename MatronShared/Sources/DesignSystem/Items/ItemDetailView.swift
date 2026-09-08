import SwiftUI
import MatronModels

/// Full detail surface for a single tracker item: header, body, item-level
/// attachments, the comment thread (including in-flight pending comments),
/// the close/reopen action bar, and the reply composer. A pure leaf view —
/// the host view model supplies everything through `Model` and the closure
/// bag, and this view never touches Journal/ViewModels directly (DesignSystem
/// may only depend on Models/Events/Search).
public struct ItemDetailView: View {
    public struct PendingComment: Equatable, Identifiable {
        public let id: String
        public let body: String
        public let attachmentCount: Int
        public let attempts: Int
        public let lastError: String?
        public init(id: String, body: String, attachmentCount: Int, attempts: Int, lastError: String?) {
            self.id = id; self.body = body; self.attachmentCount = attachmentCount; self.attempts = attempts; self.lastError = lastError
        }
    }

    public struct Model: Equatable {
        public var item: TrackerItem
        public var comments: [TrackerComment]
        public var pending: [PendingComment]
        public var originTitle: String?
        public var availableResolutions: [ItemResolution]
        public var isBusy: Bool
        public init(item: TrackerItem, comments: [TrackerComment], pending: [PendingComment], originTitle: String?, availableResolutions: [ItemResolution], isBusy: Bool) {
            self.item = item; self.comments = comments; self.pending = pending; self.originTitle = originTitle
            self.availableResolutions = availableResolutions; self.isBusy = isBusy
        }
    }

    let model: Model
    @Binding var draft: String
    let image: (TrackerAttachment) -> Image?
    let onOpenAttachment: (TrackerAttachment) -> Void
    let onOpenLink: (URL) -> Void
    let onOpenConversation: (String) -> Void
    let onSubmit: () -> Void
    let onAttach: () -> Void
    let onVoiceNote: () -> Void
    let onClose: (ItemResolution) -> Void
    let onReopen: () -> Void

    public init(model: Model, draft: Binding<String>, image: @escaping (TrackerAttachment) -> Image?,
                onOpenAttachment: @escaping (TrackerAttachment) -> Void, onOpenLink: @escaping (URL) -> Void,
                onOpenConversation: @escaping (String) -> Void, onSubmit: @escaping () -> Void, onAttach: @escaping () -> Void,
                onVoiceNote: @escaping () -> Void, onClose: @escaping (ItemResolution) -> Void, onReopen: @escaping () -> Void) {
        self.model = model; self._draft = draft; self.image = image; self.onOpenAttachment = onOpenAttachment
        self.onOpenLink = onOpenLink; self.onOpenConversation = onOpenConversation; self.onSubmit = onSubmit
        self.onAttach = onAttach; self.onVoiceNote = onVoiceNote; self.onClose = onClose; self.onReopen = onReopen
    }

    private var item: TrackerItem { model.item }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if !item.labels.isEmpty || !item.links.isEmpty { meta }
                    if !item.body.isEmpty { MarkdownText(item.body, theme: .matronMessage) }
                    attachments(item.attachments)
                    Divider()
                    ForEach(model.comments) { comment in commentView(comment) }
                    ForEach(model.pending) { p in pendingView(p) }
                }
                .padding()
            }
            Divider()
            actionBar
            ItemCommentComposer(draft: $draft, isBusy: model.isBusy, onSubmit: onSubmit, onAttach: onAttach, onVoiceNote: onVoiceNote)
        }
    }

    private var statusText: String {
        if item.needsUser { return "Needs you" }
        if item.state == .closed { return "Closed" + (item.resolution.map { " · \(ItemGlyph.label($0))" } ?? "") }
        return item.awaiting == .agent ? "With the agent" : "Open"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: ItemGlyph.symbol(item.kind)).foregroundStyle(ItemGlyph.tint(item.kind))
                Text("#\(item.num) · \(ItemGlyph.label(item.kind))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(statusText).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((item.needsUser ? Color.orange : Color.secondary).opacity(0.18), in: Capsule())
            }
            Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
            if let originTitle = model.originTitle {
                Button { onOpenConversation(item.originConvoID) } label: {
                    Label(originTitle, systemImage: "bubble.left.and.bubble.right").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.labels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.labels, id: \.self) { l in
                        Text(l).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
            }
            ForEach(item.links, id: \.url) { link in
                Button { if let u = URL(string: link.url) { onOpenLink(u) } } label: {
                    Label(link.title ?? link.url, systemImage: "link").font(.caption).lineLimit(1)
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
    }

    /// Renders a list of attachments using the shared chat-timeline
    /// primitives (`AttachmentImage` / `AttachmentFile`) so items match the
    /// conversation surface. Audio gets a bespoke waveform + transcript
    /// treatment per the tracker spec — neither shared primitive covers
    /// audio playback yet.
    @ViewBuilder
    private func attachments(_ list: [TrackerAttachment]) -> some View {
        ForEach(list, id: \.blobRef) { a in
            if a.isImage {
                AttachmentImage(image: image(a), meta: ByteCountFormatter.string(fromByteCount: a.size, countStyle: .file),
                                onTap: { onOpenAttachment(a) })
            } else if a.isAudio {
                VStack(alignment: .leading, spacing: 4) {
                    Button { onOpenAttachment(a) } label: { Label("Voice note", systemImage: "waveform") }.buttonStyle(.plain)
                    if let transcript = a.transcript, !transcript.isEmpty {
                        Text(transcript).font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("Transcribing…").font(.subheadline).foregroundStyle(.tertiary).italic()
                    }
                }
            } else {
                AttachmentFile(filename: a.name, sizeBytes: a.size, onTap: { onOpenAttachment(a) })
            }
        }
    }

    @ViewBuilder
    private func commentView(_ c: TrackerComment) -> some View {
        if c.kind == .status {
            VStack(spacing: 2) {
                Text(statusLine(c)).font(.caption).foregroundStyle(.secondary)
                if !c.body.isEmpty { Text(c.body).font(.caption).foregroundStyle(.secondary).italic() }
            }.frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(c.author == .user ? "You" : "Agent").font(.caption.weight(.semibold))
                    Text(c.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.tertiary)
                }
                if !c.body.isEmpty { MarkdownText(c.body, theme: .matronMessage) }
                attachments(c.attachments)
            }
            .padding(10)
            .background(Color.secondary.opacity(c.author == .user ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Derives the centred status line from `statusTo` (never the raw body,
    /// per the tracker spec — the raw body only renders as a secondary line
    /// beneath when non-empty, handled by the caller).
    private func statusLine(_ c: TrackerComment) -> String {
        let who = c.author == .user ? "You" : "Agent"
        guard let to = c.statusTo else { return "\(who) updated the item" }
        if to.state == .closed { return "\(who) closed this" + (to.resolution.map { " as \(ItemGlyph.label($0).lowercased())" } ?? "") }
        return "\(who) reopened this"
    }

    /// A comment queued locally (offline outbox / in-flight send) that
    /// hasn't landed in `comments` yet. Reuses `SendStateIndicator` so the
    /// caption matches the chat timeline's own queued/failed treatment
    /// instead of forking a bespoke label.
    private func pendingView(_ p: PendingComment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You").font(.caption.weight(.semibold))
            if !p.body.isEmpty { Text(p.body) }
            if p.attachmentCount > 0 { Label("\(p.attachmentCount) attachment\(p.attachmentCount == 1 ? "" : "s")", systemImage: "paperclip").font(.caption) }
            SendStateIndicator(state: p.lastError != nil ? .failed(reason: p.lastError!) : .queued)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .opacity(0.85)
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            if item.state == .open {
                Menu {
                    ForEach(model.availableResolutions, id: \.self) { r in Button(ItemGlyph.label(r)) { onClose(r) } }
                } label: { Label("Close", systemImage: "checkmark.circle") }
            } else {
                Button { onReopen() } label: { Label("Reopen", systemImage: "arrow.uturn.backward.circle") }
            }
            Spacer()
        }
        .disabled(model.isBusy)
        .padding(.horizontal).padding(.vertical, 6)
        .background(.bar)
    }
}
