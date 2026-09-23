import SwiftUI
import Foundation
import MatronEvents
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
        /// The comment count of the loaded thread, `nil` until the opening
        /// refetch has completed (`ItemDetailViewModel.loadedCommentCount`).
        /// Follow-tail only treats growth as a new reply when it starts
        /// from at least this many rows: a header-only thread is trivially
        /// "at the bottom", and treating the opening load — or a stale
        /// replay of it — as growth would jump an unread item to its end
        /// (Bugbot, PR #198). Defaulted to `nil` so existing call sites and
        /// snapshot tests stay source-compatible.
        public var loadedCommentCount: Int?
        /// The spawn consent ask this item mirrors (item #2318), derived by
        /// `ItemDetailViewModel.spawnConsent`; `nil` for every other item.
        /// Defaulted so existing call sites and snapshot tests stay
        /// source-compatible.
        public var spawnConsent: ItemSpawnConsent?
        public init(item: TrackerItem, comments: [TrackerComment], pending: [PendingComment], originTitle: String?, availableResolutions: [ItemResolution], isBusy: Bool, loadedCommentCount: Int? = nil, spawnConsent: ItemSpawnConsent? = nil) {
            self.item = item; self.comments = comments; self.pending = pending; self.originTitle = originTitle
            self.availableResolutions = availableResolutions; self.isBusy = isBusy; self.loadedCommentCount = loadedCommentCount
            self.spawnConsent = spawnConsent
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
    /// Answers the spawn consent card: `true` approves, `false` declines —
    /// the same `POST /agent-spawn/answer` the timeline card uses, via the
    /// host's view model. `nil` (previews, tests, hosts without an
    /// answerer) draws whatever state the model carries; the model itself
    /// never offers buttons when nothing is wired to them.
    let onAnswerSpawn: ((Bool) -> Void)?
    /// Opens the room a started spawn talks in. `nil` omits the Open
    /// button, as on the timeline card.
    let onOpenRoom: ((String) -> Void)?

    /// Whether the comment thread's bottom is currently visible — read by
    /// the follow-tail `.onChange(of: rowCount)` below, written by
    /// `.onScrollGeometryChange`'s `action`.
    @State private var isAtBottom = false
    /// Guards the initial `startsAtBottom` scroll to firing once per item
    /// (see `.onAppear`/`.onChange(of: item.id)` below) rather than on
    /// every body re-evaluation.
    @State private var hasScrolledToInitialBottom = false
    /// Whether the thread is taller than its viewport — reported by the
    /// same geometry callback as `isAtBottom`. Gates the jump-to-bottom
    /// button so a thread that fits on screen never offers a jump.
    @State private var isScrollable = false
    /// The item body size for plain `Text` that sits beside a markdown
    /// body (pending replies, voice transcripts): the same base and scale
    /// `Theme.matronItem` resolves to, and — because it is a
    /// `@ScaledMetric` relative to `.body`, exactly as MarkdownUI scales
    /// its own base — it grows and shrinks with Dynamic Type in step with
    /// the markdown next to it. A fixed `.system(size:)` would agree at
    /// the default size and diverge at every other.
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = ItemTypography.baseSize * ItemTypography.bodyScale
    #if os(macOS)
    /// The thread's cross-card selection (tracker #2533): the body card and
    /// every text comment render through the chat timeline's NSTextView
    /// (`SelectableMessageText`), and this controller — installed in the
    /// environment below, shadowing any chat timeline's own — lets one
    /// drag run from a card into the next, exactly as in a conversation.
    /// Owned here rather than by the host so the iOS view stays a pure leaf
    /// and the Mac hosts (pane, Decisions, Missions) need no wiring.
    @State fileprivate var cardSelection = MessageSelectionController()
    #endif

    public init(model: Model, draft: Binding<String>, image: @escaping (TrackerAttachment) -> Image?,
                onOpenAttachment: @escaping (TrackerAttachment) -> Void, onOpenLink: @escaping (URL) -> Void,
                onOpenConversation: @escaping (String) -> Void, onSubmit: @escaping () -> Void, onAttach: @escaping () -> Void,
                onVoiceNote: @escaping () -> Void, onClose: @escaping (ItemResolution) -> Void, onReopen: @escaping () -> Void,
                now: Date = Date(), startsAtBottom: Bool = false, onBottomVisibilityChange: ((Bool) -> Void)? = nil,
                onAnswerSpawn: ((Bool) -> Void)? = nil, onOpenRoom: ((String) -> Void)? = nil) {
        self.model = model; self._draft = draft; self.image = image; self.onOpenAttachment = onOpenAttachment
        self.onOpenLink = onOpenLink; self.onOpenConversation = onOpenConversation; self.onSubmit = onSubmit
        self.onAttach = onAttach; self.onVoiceNote = onVoiceNote; self.onClose = onClose; self.onReopen = onReopen
        self.now = now; self.startsAtBottom = startsAtBottom; self.onBottomVisibilityChange = onBottomVisibilityChange
        self.onAnswerSpawn = onAnswerSpawn; self.onOpenRoom = onOpenRoom
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
            #if os(macOS)
            // The Mac pane has no navigation bar of its own to host the
            // resolve/reopen menu (its pushes share the window toolbar),
            // so a slim pinned row above the thread stands in — pinned,
            // not in the scrolling header, so it stays reachable after
            // reading to the tail (Bugbot). The iOS host puts the same
            // control in the navigation bar.
            HStack {
                Spacer()
                ItemResolveControl(isOpen: item.state == .open, resolutions: model.availableResolutions, isBusy: model.isBusy,
                                   onClose: onClose, onReopen: onReopen)
                    .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 12).padding(.top, 8)
            #endif
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: ItemTypography.threadSpacing) {
                        header
                        if !item.labels.isEmpty || !item.links.isEmpty { meta }
                        if let consent = model.spawnConsent { spawnConsentCard(consent) }
                        if !item.body.isEmpty || !item.attachments.isEmpty { bodyCard }
                        Divider()
                        ForEach(model.comments) { comment in commentView(comment) }
                        ForEach(model.pending) { p in pendingView(p) }
                        Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                    }
                    // A reading measure, not a chat column: the thread caps
                    // at `ItemTypography.measure` and centres in whatever
                    // width the host gives it (a dragged-wide Mac pane, the
                    // narrow takeover, an iPad) instead of stretching every
                    // line across the window (tracker #66).
                    .frame(maxWidth: ItemTypography.measure, alignment: .leading)
                    .padding()
                    .frame(maxWidth: .infinity)
                }
                .onItemThreadGeometryChange { geometry in
                    isAtBottom = geometry.atBottom
                    isScrollable = geometry.scrollable
                    onBottomVisibilityChange?(geometry.atBottom)
                }
                // Dragging the thread down through the keyboard hides it,
                // as in the chat timeline — the composer row's own
                // pull-down (`dragDownDismissesKeyboard`) covers the
                // other place people reach for.
                .scrollDismissesKeyboard(.interactively)
                // Floating jump-to-latest, the chat timeline's own
                // affordance, shown once the reader has scrolled away from
                // the tail of a thread that actually overflows.
                .overlay(alignment: .bottomTrailing) {
                    if Self.showsJumpToBottom(placed: hasScrolledToInitialBottom, scrollable: isScrollable, atBottom: isAtBottom) {
                        JumpToBottomButton {
                            isAtBottom = true
                            withAnimation { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: isAtBottom)
                .animation(.easeInOut(duration: 0.18), value: isScrollable)
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
                    guard Self.shouldFollowTail(loadedCount: model.loadedCommentCount, startsAtBottom: startsAtBottom,
                                                placed: hasScrolledToInitialBottom, atBottom: isAtBottom,
                                                oldCount: oldCount, newCount: newCount) else { return }
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .cardSelection(self)
            }
            Divider()
            ItemCommentComposer(draft: $draft, isBusy: model.isBusy, onSubmit: onSubmit, onAttach: onAttach, onVoiceNote: onVoiceNote)
        }
        // The chat timeline's cream ground (warm-dark in dark mode) under
        // thread, action bar and composer alike — an item thread used to
        // sit on the bare system background, solid black in dark mode,
        // unlike every other reading surface in the app.
        .background(MatronTimelineBackground())
    }

    /// Whether the jump-to-bottom button is offered: only after the
    /// initial placement has run (so it can't flash during the opening
    /// scroll), only when the thread overflows its viewport (a short
    /// thread has nowhere to jump; before the first geometry callback
    /// `scrollable` is false, which keeps a freshly opened item quiet),
    /// and only while the reader is away from the bottom.
    static func showsJumpToBottom(placed: Bool, scrollable: Bool, atBottom: Bool) -> Bool {
        placed && scrollable && !atBottom
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
        // `isScrollable` is deliberately NOT reset here. Geometry only
        // re-reports when the (atBottom, scrollable) pair actually changes,
        // so a Mac in-place swap between two overflowing threads would
        // never restore a cleared flag and the jump button would stay
        // hidden for good (Bugbot, round 2). Left alone, a swap onto a
        // thread with different overflow flips it as soon as the new
        // content is measured — a same-pass update, not a visible flash —
        // and a swap between like threads has nothing to correct.
        guard startsAtBottom else { return }
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
    }

    /// The follow-tail decision for a thread that just grew (Bugbot, PR
    /// #198, rounds 1–4). Only re-pins when the growth started from a
    /// thread that was already loaded — `oldCount` at or above
    /// `loadedCount` — so the opening refetch of an unread item is never
    /// mistaken for a new reply, whichever SwiftUI update the loaded count
    /// lands in (same update as the rows: old 0 < loaded 8; a later one:
    /// loaded still nil) and even if a stale pre-refetch snapshot replays
    /// afterwards (8→3 shrinks, 3→8 starts below 8). Also requires the
    /// initial placement to have run, the reader at the bottom, and real
    /// growth (a removed comment must not yank the viewport). A
    /// `startsAtBottom` reader is exempt from the load gate: they asked
    /// for the tail, `placeInitially` marked them at-bottom before any
    /// geometry callback, and the rows landing during the load are
    /// exactly what must keep them pinned there.
    static func shouldFollowTail(loadedCount: Int?, startsAtBottom: Bool, placed: Bool, atBottom: Bool,
                                 oldCount: Int, newCount: Int) -> Bool {
        guard placed, atBottom, newCount > oldCount else { return false }
        if startsAtBottom { return true }
        guard let loadedCount else { return false }
        return oldCount >= loadedCount
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
            Text(item.title).font(ItemTypography.titleFont).textSelection(.enabled)
            if let originTitle = model.originTitle {
                Button { onOpenConversation(item.originConvoID) } label: {
                    Label(originTitle, systemImage: "bubble.left.and.bubble.right").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    /// The original post — body and item-level attachments — in the same
    /// card as a comment, captioned with who filed it and when, so the
    /// thread reads as one conversation instead of a bare body followed
    /// by carded replies (tracker #72). Tinted like a comment from the
    /// same author.
    private var bodyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            authorCaption(item.createdBy, date: item.createdAt)
            if !item.body.isEmpty { itemBody(item.body, selectionID: Self.bodySelectionID(for: item.id)) }
            attachments(item.attachments)
        }
        .itemCard(mine: item.createdBy == .user)
    }

    /// A markdown body at the item reading scale with the thread's leading
    /// — one call for the item body and every comment. On the Mac it is the
    /// chat timeline's selectable NSTextView at `MarkdownAttributed.Style
    /// .item`, so a drag selects across paragraphs, lists and code — and,
    /// through `cardSelection`, across cards (tracker #2533). MarkdownUI's
    /// per-block `Text`s (`Theme.matronItem`) stay on iOS, where selection
    /// is a long-press affair and cannot span blocks either way.
    @ViewBuilder
    private func itemBody(_ markdown: String, selectionID: String) -> some View {
        #if os(macOS)
        SelectableMessageText(markdown, itemID: selectionID, style: .item)
        #else
        MarkdownText(markdown, theme: .matronItem, lineSpacing: ItemTypography.lineSpacing)
        #endif
    }

    /// The selection id of the body card. Prefixed so it can never collide
    /// with a comment id — both are journal ids, and the selection
    /// controller keys its targets by id.
    static func bodySelectionID(for itemID: String) -> String { "body:" + itemID }

    /// Row order for the cross-card selection: the body card first (when
    /// it renders at all — a body or attachments), then every comment
    /// that is not a status row. A card with no text (a voice note, a
    /// file) has no text view to highlight, but it is still a row a drag
    /// passes THROUGH, and the transcript stands in a marker for it — the
    /// chat timeline's rule for an uncaptioned image (reviewer, PR #232).
    static func selectionOrder(item: TrackerItem, comments: [TrackerComment]) -> [String] {
        var ids: [String] = []
        if !item.body.isEmpty || !item.attachments.isEmpty { ids.append(bodySelectionID(for: item.id)) }
        ids += comments.filter { $0.kind != .status }.map(\.id)
        return ids
    }

    /// "You · 5 min ago" / "Agent · 3 Sept" above a card's body.
    private func authorCaption(_ author: ItemAuthor, date: Date) -> some View {
        HStack(spacing: 4) {
            Text(author == .user ? "You" : "Agent").font(ItemTypography.captionFont.weight(.semibold))
            Text("· \(relativeDate(date))").font(ItemTypography.captionDetailFont).foregroundStyle(.tertiary)
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

    /// The spawn consent card for a consent item (item #2318), between the
    /// meta row and the body so the answer sits near the top of the thread.
    /// The full `AgentSpawnRequestCard` when the card's own event is in the
    /// local store — its task is then byte-for-byte what the timeline card
    /// shows. Without it there is nothing to approve: the id in the item's
    /// link is agent-written and could name an ask the user has never seen,
    /// so the placeholder says the card has not arrived and offers no
    /// buttons; the view model re-derives the moment it syncs. The body
    /// stays either way; it holds facts (model, room flag) the card does
    /// not draw.
    @ViewBuilder
    private func spawnConsentCard(_ consent: ItemSpawnConsent) -> some View {
        if let request = consent.request {
            AgentSpawnRequestCard(request: request, state: consent.state,
                                  onApprove: { onAnswerSpawn?(true) }, onDeny: { onAnswerSpawn?(false) },
                                  onOpen: onOpenRoom)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("Agent spawn request").font(.callout.weight(.semibold))
                } icon: {
                    Image(systemName: "sparkles.rectangle.stack").foregroundStyle(.tint)
                }
                Text("The request card hasn't reached this device yet. It can be approved once it arrives, or from the conversation it was asked in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.matronBubbleBot)
                    .shadow(color: .matronBubbleShadow, radius: 2, y: 1)
            )
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
                        Text(transcript).font(.system(size: bodySize)).lineSpacing(ItemTypography.lineSpacing).foregroundStyle(.secondary)
                    } else if a.transcriptionFailed {
                        Text("Couldn’t transcribe — tap to listen").font(.subheadline).foregroundStyle(.tertiary).italic()
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
            VStack(alignment: .leading, spacing: 6) {
                authorCaption(c.author, date: c.createdAt)
                if !c.body.isEmpty { itemBody(c.body, selectionID: c.id) }
                attachments(c.attachments)
            }
            .itemCard(mine: c.author == .user)
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
        VStack(alignment: .leading, spacing: 6) {
            Text("You").font(ItemTypography.captionFont.weight(.semibold))
            if !p.body.isEmpty { Text(p.body).font(.system(size: bodySize)).lineSpacing(ItemTypography.lineSpacing) }
            if p.attachmentCount > 0 { Label("\(p.attachmentCount) attachment\(p.attachmentCount == 1 ? "" : "s")", systemImage: "paperclip").font(.caption) }
            SendStateIndicator(state: pendingState(p))
        }
        .itemCard(mine: true)
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
}

#if os(macOS)
extension ItemDetailView {
    /// The pasteboard text for a finished cross-card selection — the chat
    /// timeline's own "[date] Name: text" shape (`TranscriptFormatter`),
    /// one entry per selected card in row order. The selected text comes
    /// first; each attachment follows on its own line as a marker
    /// (`attachmentMarker`), so a voice-note reply copies its transcript
    /// rather than vanishing. A card whose text view exists but has
    /// nothing selected (the pointer sat in the gap above it) and an id
    /// that no longer names a card contribute nothing. The reader is
    /// "Me", as in the timeline; the agent is "Agent", as in the captions.
    static func transcript(item: TrackerItem, comments: [TrackerComment], spans: [SelectedSpan],
                           locale: Locale = .current, timeZone: TimeZone = .current) -> SelectionTranscript {
        var entries: [TranscriptEntry] = []
        for span in spans {
            let author: ItemAuthor
            let date: Date
            let attachments: [TrackerAttachment]
            if span.id == bodySelectionID(for: item.id) {
                author = item.createdBy
                date = item.createdAt
                attachments = item.attachments
            } else if let comment = comments.first(where: { $0.id == span.id }) {
                author = comment.author
                date = comment.createdAt
                attachments = comment.attachments
            } else {
                continue
            }
            // `""` means a text view exists and none of it is selected —
            // skip the whole card, markers included, as the timeline does
            // for an image whose caption view has an empty selection.
            if let text = span.text, text.isEmpty { continue }
            var lines: [String] = []
            if let text = span.text { lines.append(text) }
            lines += attachments.map(attachmentMarker)
            guard !lines.isEmpty else { continue }
            entries.append(TranscriptEntry(timestamp: date, name: author == .user ? "Me" : "Agent",
                                           text: lines.joined(separator: "\n")))
        }
        return SelectionTranscript(text: TranscriptFormatter.format(entries, locale: locale, timeZone: timeZone),
                                   messageCount: entries.count)
    }

    /// What an attachment contributes to a copied transcript: a voice
    /// note carries its transcript (the words are what the reader wants),
    /// an image the timeline's `[Photo]`, anything else `[File: name]`.
    static func attachmentMarker(_ attachment: TrackerAttachment) -> String {
        if attachment.isAudio {
            if let transcript = attachment.transcript, !transcript.isEmpty { return "[Voice note] " + transcript }
            return "[Voice note]"
        }
        if attachment.isImage { return "[Photo]" }
        return "[File: \(attachment.name)]"
    }

    /// Row order as the controller wants it, recomputed from the model.
    fileprivate var selectionOrder: [String] { Self.selectionOrder(item: item, comments: model.comments) }

    /// Installs the spans → transcript bridge for `model` — the value the
    /// `onChange` that calls this just received, captured by value:
    /// comments are immutable once posted and the provider is re-installed
    /// whenever the model changes, so what a finished selection copies is
    /// what the cards showed when it finished.
    fileprivate func installTranscriptProvider(for model: Model) {
        cardSelection.transcriptProvider = { [weak cardSelection] in
            guard let cardSelection else { return SelectionTranscript(text: "", messageCount: 0) }
            return Self.transcript(item: model.item, comments: model.comments, spans: cardSelection.selectedSpans())
        }
    }
}
#endif

private extension View {
    /// The Mac cross-card selection plumbing on the thread's scroll view
    /// (tracker #2533): the controller in the environment for every
    /// `SelectableMessageText` under it, the row order kept in step with
    /// the model, the transcript provider re-installed as comments land,
    /// and the selection dropped on the way out so its clear-monitor does
    /// not outlive the thread. No-op on iOS.
    @ViewBuilder
    func cardSelection(_ detail: ItemDetailView) -> some View {
        #if os(macOS)
        self
            .environment(detail.cardSelection)
            .onChange(of: detail.selectionOrder, initial: true) { _, order in
                detail.cardSelection.orderedIDs = order
            }
            .onChange(of: detail.model, initial: true) { _, model in
                detail.installTranscriptProvider(for: model)
            }
            .onDisappear { detail.cardSelection.clear() }
        #else
        self
        #endif
    }

    /// The thread's card chrome — the chat bubble surfaces on a rounded
    /// rectangle with the bubble shadow — shared by the body card, the
    /// comment cards and the pending rows so they read as one thread.
    func itemCard(mine: Bool) -> some View {
        self
            .padding(ItemTypography.cardPadding)
            .background(mine ? Color.matronBubbleMe : Color.matronBubbleBot, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .matronBubbleShadow, radius: 2, y: 1)
    }

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
    func onItemThreadGeometryChange(action: @escaping (ItemThreadGeometry) -> Void) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            self.onScrollGeometryChange(for: ItemThreadGeometry.self) { geometry in
                ItemThreadGeometry(
                    atBottom: geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 8,
                    scrollable: geometry.contentSize.height > geometry.containerSize.height + 8
                )
            } action: { _, geometry in
                action(geometry)
            }
        } else {
            self
        }
    }
}

/// The two facts `ItemDetailView` needs from the thread's scroll geometry.
struct ItemThreadGeometry: Equatable {
    var atBottom: Bool
    var scrollable: Bool
}
