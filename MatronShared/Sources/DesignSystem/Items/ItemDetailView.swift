import SwiftUI
import Foundation
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
        /// Whether `comments` is the loaded thread rather than the pre-refetch
        /// cache (`ItemDetailViewModel.hasLoadedThread`). While `false` the
        /// view neither follows the tail nor reports bottom visibility —
        /// a header-only thread is trivially "at the bottom", and treating
        /// the initial load as growth would jump an unread item to its end
        /// and persist it as read-to-end (Bugbot, PR #198). Defaulted to
        /// `true` so snapshot tests, which hand over a finished thread,
        /// stay source-compatible.
        public var threadLoaded: Bool
        public init(item: TrackerItem, comments: [TrackerComment], pending: [PendingComment], originTitle: String?, availableResolutions: [ItemResolution], isBusy: Bool, threadLoaded: Bool = true) {
            self.item = item; self.comments = comments; self.pending = pending; self.originTitle = originTitle
            self.availableResolutions = availableResolutions; self.isBusy = isBusy; self.threadLoaded = threadLoaded
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
    /// Reference instant for relative comment-date captions ("5 min ago").
    /// Defaulted to `Date()` so existing/host call sites stay source-compatible;
    /// snapshot tests pass a fixed instant so the thread renders deterministically.
    let now: Date
    /// Whether the reader had previously scrolled to the bottom of this
    /// item's thread (`ItemReadMemory.wasAtBottom(itemID:)`, read once by
    /// the host) — mirrors the chat timeline opening at the tail when the
    /// reader was following it. Defaulted so existing call sites/snapshot
    /// tests stay source-compatible.
    let startsAtBottom: Bool
    /// Reports whether the comment thread's bottom is currently visible,
    /// so the host can persist it for next time. Defaulted to `nil` for
    /// the same reason.
    let onBottomVisibilityChange: ((Bool) -> Void)?

    /// Whether the comment thread's bottom is currently visible — read by
    /// the follow-tail `.onChange(of: rowCount)` below, written by
    /// `.onScrollGeometryChange`'s `action`.
    @State private var isAtBottom = false
    /// Guards the initial `startsAtBottom` scroll to firing once per item
    /// (see `.onAppear`/`.onChange(of: item.id)` below) rather than on
    /// every body re-evaluation.
    @State private var hasScrolledToInitialBottom = false

    public init(model: Model, draft: Binding<String>, image: @escaping (TrackerAttachment) -> Image?,
                onOpenAttachment: @escaping (TrackerAttachment) -> Void, onOpenLink: @escaping (URL) -> Void,
                onOpenConversation: @escaping (String) -> Void, onSubmit: @escaping () -> Void, onAttach: @escaping () -> Void,
                onVoiceNote: @escaping () -> Void, onClose: @escaping (ItemResolution) -> Void, onReopen: @escaping () -> Void,
                now: Date = Date(), startsAtBottom: Bool = false, onBottomVisibilityChange: ((Bool) -> Void)? = nil) {
        self.model = model; self._draft = draft; self.image = image; self.onOpenAttachment = onOpenAttachment
        self.onOpenLink = onOpenLink; self.onOpenConversation = onOpenConversation; self.onSubmit = onSubmit
        self.onAttach = onAttach; self.onVoiceNote = onVoiceNote; self.onClose = onClose; self.onReopen = onReopen
        self.now = now; self.startsAtBottom = startsAtBottom; self.onBottomVisibilityChange = onBottomVisibilityChange
    }

    private var item: TrackerItem { model.item }

    /// Stable id the `ScrollViewReader` scrolls to — an invisible spacer
    /// after the last comment/pending row, not a row's own id, so it
    /// stays valid even when the thread is empty.
    private static let bottomAnchorID = "bottom"

    /// Row count driving the follow-tail re-pin below: comments plus
    /// locally-queued pending ones, since either landing is "the thread
    /// grew" from the reader's point of view.
    private var rowCount: Int { model.comments.count + model.pending.count }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        if !item.labels.isEmpty || !item.links.isEmpty { meta }
                        if !item.body.isEmpty { MarkdownText(item.body, theme: .matronMessage) }
                        attachments(item.attachments)
                        Divider()
                        ForEach(model.comments) { comment in commentView(comment) }
                        ForEach(model.pending) { p in pendingView(p) }
                        Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                    }
                    .padding()
                }
                .onItemThreadBottomVisibilityChange { atBottom in
                    // Pre-load geometry is the header alone (or a stale
                    // cache) and says nothing about where the reader is in
                    // the real thread — ignore it rather than arm the
                    // follow-tail below or persist a false read-to-end.
                    guard model.threadLoaded else { return }
                    isAtBottom = atBottom
                    onBottomVisibilityChange?(atBottom)
                }
                .onAppear {
                    guard !hasScrolledToInitialBottom else { return }
                    placeInitially(proxy)
                }
                // The Mac host swaps items in place — same `ItemDetailView`
                // call site, new `model.item` — which SwiftUI treats as the
                // SAME view identity, so `.onAppear` above only fires once
                // for the whole lifetime, not per item. This re-runs the
                // initial-scroll decision whenever the item underneath an
                // unchanged identity actually changes; on iOS, where each
                // item gets a fresh push (and so a fresh identity), this is
                // a harmless no-op duplicate of `.onAppear`.
                .onChange(of: item.id) { _, _ in
                    placeInitially(proxy)
                }
                // Follow-tail: once the reader has settled at the bottom, a
                // newly-arrived comment (or a locally-queued pending one)
                // re-pins the viewport there, mirroring the chat timeline.
                // `newCount > oldCount` (not just "changed") so a comment
                // being removed doesn't yank the viewport, and gating on
                // `hasScrolledToInitialBottom` means this never fires
                // before the initial placement above has had its say.
                .onChange(of: rowCount) { oldCount, newCount in
                    guard Self.shouldFollowTail(threadLoaded: model.threadLoaded, startsAtBottom: startsAtBottom,
                                                placed: hasScrolledToInitialBottom, atBottom: isAtBottom,
                                                oldCount: oldCount, newCount: newCount) else { return }
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            Divider()
            actionBar
            ItemCommentComposer(draft: $draft, isBusy: model.isBusy, onSubmit: onSubmit, onAttach: onAttach, onVoiceNote: onVoiceNote)
        }
    }

    /// The one-time placement decision for an item (Bugbot, PR #198): it
    /// is made whether or not we scroll — staying at the top still arms
    /// follow-tail — and a bottom placement also marks the reader as AT
    /// the bottom straight away, so comments that land after the first
    /// `scrollTo` (they arrive on their own stream) re-pin the tail before
    /// the first geometry callback has said anything.
    private func placeInitially(_ proxy: ScrollViewProxy) {
        hasScrolledToInitialBottom = true
        isAtBottom = startsAtBottom
        guard startsAtBottom else { return }
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
    }

    /// The follow-tail decision for a thread that just grew (Bugbot, PR
    /// #198, rounds 1–3). Only re-pins when the thread had already loaded
    /// before this growth — so the opening refetch of an unread item is
    /// never mistaken for a new reply — AND the initial placement has run
    /// AND the reader was at the bottom AND the thread actually grew (a
    /// removed comment must not yank the viewport). A `startsAtBottom`
    /// reader is exempt from the load gate: they asked for the tail,
    /// `placeInitially` marked them at-bottom before any geometry
    /// callback, and the cached-then-refetched rows landing during the
    /// load are exactly what must keep them pinned there (round 3: gating
    /// them too reopened a read-to-end thread at the top and then stored
    /// it as unread).
    static func shouldFollowTail(threadLoaded: Bool, startsAtBottom: Bool, placed: Bool, atBottom: Bool,
                                 oldCount: Int, newCount: Int) -> Bool {
        (threadLoaded || startsAtBottom) && placed && atBottom && newCount > oldCount
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
                if let line = statusLine(c) { Text(line).font(.caption).foregroundStyle(.secondary) }
                if !c.body.isEmpty { Text(c.body).font(.caption).foregroundStyle(.secondary).italic() }
            }.frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(c.author == .user ? "You" : "Agent").font(.caption.weight(.semibold))
                    Text("· \(relativeDate(c.createdAt))").font(.caption2).foregroundStyle(.tertiary)
                }
                if !c.body.isEmpty { MarkdownText(c.body, theme: .matronMessage) }
                attachments(c.attachments)
            }
            .padding(10)
            .background(Color.secondary.opacity(c.author == .user ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Relative caption for a comment's timestamp ("5 min ago"), computed
    /// against `now` (not the ambient clock) so snapshot tests are
    /// deterministic. Falls back to an absolute short date once the comment
    /// is more than 7 days older than `now` — "3 mo. ago" reads worse than
    /// an actual date once relative units stop being useful at that range.
    private func relativeDate(_ date: Date) -> String {
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        if now.timeIntervalSince(date) > sevenDays {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Derives the centred status line from `statusTo` (never the raw body,
    /// per the tracker spec — the raw body only renders as a secondary line
    /// beneath when non-empty, handled by the caller).
    ///
    /// Fix wave, item I: this used to say "reopened" for ANY status row
    /// whose `to.state` wasn't `.closed` — including a pure awaiting-only
    /// change (e.g. the agent handing an open item back to the user),
    /// which was never a reopen at all. "Reopened" now only fires on an
    /// actual closed→open transition; other non-closing changes describe
    /// the awaiting change instead, and a status row that changed neither
    /// (state nor awaiting) renders no line — `nil`, not empty-string, so
    /// the caller can skip the row instead of showing a blank line above
    /// a body it already renders separately.
    private func statusLine(_ c: TrackerComment) -> String? {
        let who = c.author == .user ? "You" : "Agent"
        guard let to = c.statusTo else { return "\(who) updated the item" }
        if to.state == .closed {
            return "\(who) closed this" + (to.resolution.map { " as \(ItemGlyph.label($0).lowercased())" } ?? "")
        }
        if c.statusFrom?.state == .closed, to.state == .open {
            return "\(who) reopened this"
        }
        if let toAwaiting = to.awaiting, toAwaiting != c.statusFrom?.awaiting {
            return toAwaiting == .agent ? "Now with the agent" : "Needs you"
        }
        return nil
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
            SendStateIndicator(state: pendingState(p))
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .opacity(0.85)
    }

    /// Maps outbox progress to the shared glyph: a fresh comment that
    /// hasn't attempted a send yet reads as "Sending…"; once at least one
    /// attempt has been made without an error it's genuinely waiting on
    /// connectivity ("Queued"); any recorded error wins and shows the
    /// retry affordance regardless of attempt count.
    private func pendingState(_ p: PendingComment) -> SendStateGlyph {
        if let lastError = p.lastError { return .failed(reason: lastError) }
        if p.attempts > 0 { return .queued }
        return .sending
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

private extension View {
    /// Reports whether a `ScrollView`'s bottom is currently visible, via
    /// `onScrollGeometryChange` (iOS 18 / macOS 15 — same wave as
    /// `onUserScrollGesture`'s `onScrollPhaseChange`, see that file). The
    /// app's real deployment target is 18/15 (`project.yml`), but
    /// `MatronShared`'s own declared package platforms are more
    /// conservative (iOS 17 / macOS 14), so this still needs the
    /// availability guard to typecheck; the `else` branch is a no-op
    /// (`ItemDetailView.onBottomVisibilityChange` just never fires,
    /// falling back to the existing "always opens at the top" behaviour).
    @ViewBuilder
    func onItemThreadBottomVisibilityChange(action: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            self.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 8
            } action: { _, atBottom in
                action(atBottom)
            }
        } else {
            self
        }
    }
}
