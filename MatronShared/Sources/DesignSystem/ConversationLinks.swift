import Foundation
import SwiftUI
import os

// Conversation links (decision #2954).
//
// Agents mention other conversations as ordinary markdown links —
// `[Auth refactor](matron://convo/<conversation id>)` — the way they already
// reference tracker items (`MatronItemLink`). Two things read them:
//
// - the message renderers, which route a tapped inline link through the
//   `\.openConversation` environment action (never to the OS: the `matron`
//   scheme is registered with nothing), and
// - `ConversationLinkPillRow`, a row of capsule buttons under the bubble
//   naming each linked conversation by its CURRENT title.
//
// Both land in `ConversationLinkHost`, installed once per window/shell by
// `conversationLinks(_:open:)`, which checks the id against the local journal
// store before the host navigates — an unknown id opens nothing.

// MARK: - Extraction

/// One conversation link in a message body: the validated id and the
/// link's visible text (the fallback label when the store has no title).
public struct ConversationLinkRef: Hashable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// Pulls the `matron://convo/<id>` links out of a markdown body, in order of
/// first appearance, de-duplicated by id (the first link's text wins).
///
/// Parsed with Foundation's markdown parser, so exactly what renders as a
/// link counts: a bare `matron://convo/x` in prose, or a link inside a code
/// span, is not a link and yields no pill. Every timeline row calls this on
/// every body evaluation, so the common case — a body with no conversation
/// link at all — is a substring check that never reaches the parser, and
/// parsed results are memoised by source.
public enum ConversationLinkRefs {
    public static func extract(from markdown: String) -> [ConversationLinkRef] {
        guard markdown.range(of: "matron://convo/", options: .caseInsensitive) != nil else { return [] }
        let key = markdown as NSString
        if let cached = cache.object(forKey: key) { return cached.refs }
        let refs = parse(markdown)
        cache.setObject(Entry(refs), forKey: key)
        return refs
    }

    private static func parse(_ markdown: String) -> [ConversationLinkRef] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return [] }
        var seen = Set<String>()
        var refs: [ConversationLinkRef] = []
        // `runs[\.link]` coalesces a link's runs (bold, italic…) into one
        // range per contiguous link, so formatted link text reads as one.
        for (link, range) in parsed.runs[\.link] {
            guard let link, let id = MatronItemLink.conversationID(from: link),
                  seen.insert(id).inserted else { continue }
            let text = String(parsed[range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            refs.append(ConversationLinkRef(id: id, text: text))
        }
        return refs
    }

    private final class Entry {
        let refs: [ConversationLinkRef]
        init(_ refs: [ConversationLinkRef]) { self.refs = refs }
    }

    /// Thread-safe, evicts under pressure. Only bodies that contain a
    /// conversation link are ever inserted, so the limit is generous.
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 256
        return cache
    }()
}

/// How a row of pills is cut: the first `maxVisible` as pills, the rest
/// behind a "+N" menu.
public struct ConversationPillLayout: Equatable {
    public static let maxVisible = 4
    public let visible: [ConversationLinkRef]
    public let overflow: [ConversationLinkRef]

    public init(refs: [ConversationLinkRef]) {
        visible = Array(refs.prefix(Self.maxVisible))
        overflow = Array(refs.dropFirst(Self.maxVisible))
    }
}

// MARK: - Titles

/// What the local journal store knows about a linked conversation.
public enum ConversationLinkTitle: Equatable, Sendable {
    /// On this device; the title may still be empty.
    case known(String)
    /// Never synced here — deleted, another account's, or a bad id.
    case unknown
}

/// A pill's label and whether it can open anything.
public enum ConversationLinkLabel {
    /// The conversation's current title, else the link's own text, else
    /// "Conversation". `title == nil` means not looked up yet.
    public static func text(for ref: ConversationLinkRef, title: ConversationLinkTitle?) -> String {
        if case .known(let current) = title {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let text = ref.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Conversation" : text
    }

    /// Only a conversation this device has can be opened.
    public static func isOpenable(_ title: ConversationLinkTitle?) -> Bool {
        if case .known = title { return true }
        return false
    }
}

// MARK: - Host

/// One tap on a conversation link or pill. The `id` makes two taps on the
/// same conversation two distinct values, so the host's `onChange` sees both.
public struct ConversationLinkTap: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let convoID: String
    public init(convoID: String) { self.convoID = convoID }
}

/// Title cache + tap relay for one window (Mac) or the signed-in shell
/// (iOS), held in `@State` by the host view.
///
/// `action` is ONE closure for the host's lifetime: every rendered message
/// body reads it from the environment, so a fresh closure per parent
/// evaluation would churn the environment under the whole timeline (see
/// `TrackerItemLinkRelay`, the same pattern for item links).
///
/// Rows never read this object — only the pill views inside them do — so a
/// title arriving invalidates the pills and nothing else; the timeline's
/// per-row `Equatable` gate is untouched.
@MainActor @Observable
public final class ConversationLinkHost {
    /// Looked-up conversations. Only ids some pill asked about are here.
    public private(set) var titles: [String: ConversationLinkTitle] = [:]
    /// The most recent tap; see `ConversationLinkTap`.
    public private(set) var pending: ConversationLinkTap?
    /// Bumped by `reset(lookup:)`. Pills key their load on it, so a pill
    /// that loaded against the previous (or the default, know-nothing)
    /// lookup loads again — the host's session task and a restored chat's
    /// pills start in no guaranteed order.
    public private(set) var generation = 0

    /// The environment action. Same instance for this host's lifetime.
    @ObservationIgnored public private(set) var action: (String) -> Void = { _ in }
    @ObservationIgnored private var lookup: (String) async -> ConversationLinkTitle

    /// - Parameter lookup: reads the local journal store — `.unknown` for an
    ///   id this device has never seen. Defaults to knowing nothing, for a
    ///   host built before its session resolves (see `reset(lookup:)`).
    public init(lookup: @escaping (String) async -> ConversationLinkTitle = { _ in .unknown }) {
        self.lookup = lookup
        action = { [weak self] convoID in self?.pending = ConversationLinkTap(convoID: convoID) }
    }

    public func title(for convoID: String) -> ConversationLinkTitle? { titles[convoID] }

    /// Re-reads one conversation. Always a fresh read — a pill appearing is
    /// the moment its title must be current — but only written back when it
    /// changed, so a no-op read invalidates nothing.
    public func load(_ convoID: String) async {
        store(await lookup(convoID), for: convoID)
    }

    /// Folds a chat-list snapshot into the conversations a pill is already
    /// showing, so a rename or a newly synced conversation updates pills on
    /// screen. Ids no pill asked about are ignored, and with no pill ever
    /// shown this returns before touching the snapshot — it runs on every
    /// list snapshot, up to several a second while agents stream.
    public func absorb(_ listTitles: [ListTitle]) {
        guard !titles.isEmpty else { return }
        for entry in listTitles where titles[entry.id] != nil {
            store(.known(entry.title), for: entry.id)
        }
    }

    /// One chat-list row's id and title, as `absorb(_:)` takes them.
    public struct ListTitle: Equatable, Sendable {
        public let id: String
        public let title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// Points the host at a new store (sign-in, account switch): forgets
    /// every title the old lookup produced.
    public func reset(lookup: @escaping (String) async -> ConversationLinkTitle) {
        self.lookup = lookup
        titles = [:]
        generation += 1
    }

    /// `reset(lookup:)` over a store read that answers `nil` for an unknown
    /// conversation (`JournalStore.conversationTitle(id:)`). A failed read
    /// counts as unknown: the pill disables rather than offering a tap that
    /// could land on a conversation that isn't there.
    public func reset(titleLookup: @escaping (String) async throws -> String?) {
        reset(lookup: { convoID in
            guard let title = try? await titleLookup(convoID) else { return .unknown }
            return .known(title)
        })
    }

    /// The conversation `tap` should open, or `nil`: unknown to this device,
    /// or superseded by a newer tap while the lookup ran (last tap wins).
    public func resolve(_ tap: ConversationLinkTap) async -> String? {
        await load(tap.convoID)
        guard pending?.id == tap.id, ConversationLinkLabel.isOpenable(titles[tap.convoID]) else {
            Self.log.debug("conversation link not opened: unknown or superseded")
            return nil
        }
        return tap.convoID
    }

    private func store(_ title: ConversationLinkTitle, for convoID: String) {
        if titles[convoID] != title { titles[convoID] = title }
    }

    private static let log = Logger(subsystem: "chat.matron", category: "ConversationLinks")
}

// MARK: - Environment

/// Opens a conversation by journal id. `nil` — the default — means no host is
/// installed, and conversation links are swallowed rather than handed to the
/// OS. Installed by `conversationLinks(_:open:)`.
struct OpenConversationKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

struct ConversationLinkHostKey: EnvironmentKey {
    static let defaultValue: ConversationLinkHost? = nil
}

extension EnvironmentValues {
    public var openConversation: ((String) -> Void)? {
        get { self[OpenConversationKey.self] }
        set { self[OpenConversationKey.self] = newValue }
    }

    public var conversationLinkHost: ConversationLinkHost? {
        get { self[ConversationLinkHostKey.self] }
        set { self[ConversationLinkHostKey.self] = newValue }
    }
}

private struct ConversationLinksModifier: ViewModifier {
    let host: ConversationLinkHost
    let open: (String) -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.openConversation, host.action)
            .environment(\.conversationLinkHost, host)
            .onChange(of: host.pending) { _, tap in
                guard let tap else { return }
                Task { @MainActor in
                    if let convoID = await host.resolve(tap) { open(convoID) }
                }
            }
    }
}

extension View {
    /// Installs `host` as the conversation-link host for everything below:
    /// the inline-link action every message body reads, the title source the
    /// pills read, and the tap → `open` hop. `open` runs only for a
    /// conversation the local store knows, and only for the latest tap.
    /// Apply ONCE, at the window / shell root.
    public func conversationLinks(_ host: ConversationLinkHost,
                                  open: @escaping (String) -> Void) -> some View {
        modifier(ConversationLinksModifier(host: host, open: open))
    }
}

/// Keeps a host's pill titles live from the chat list. An invisible view,
/// so reading the list snapshot subscribes only THIS body — the shell that
/// places it is not re-evaluated on every snapshot. With no pill ever shown
/// the snapshot is not even read.
public struct ConversationLinkTitleFeed: View {
    let host: ConversationLinkHost
    let snapshot: () -> [ConversationLinkHost.ListTitle]

    public init(host: ConversationLinkHost, snapshot: @escaping () -> [ConversationLinkHost.ListTitle]) {
        self.host = host
        self.snapshot = snapshot
    }

    public var body: some View {
        let entries = host.titles.isEmpty ? [] : snapshot()
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: entries) { _, latest in host.absorb(latest) }
    }
}

// MARK: - Pills

/// The pill row under a message bubble: one capsule per linked conversation
/// (first four; the rest behind "+N"), laid out to line up with the bubble
/// above it — same author edge, same readable cap, same avatar inset.
///
/// Renders nothing for an empty `refs`, but callers skip it entirely then so
/// a plain message keeps its original view structure.
public struct ConversationLinkPillRow: View {
    let refs: [ConversationLinkRef]
    let style: MessageAuthorStyle
    /// Whether the bubble above is indented by a sender avatar.
    let hasAvatar: Bool

    public init(refs: [ConversationLinkRef], style: MessageAuthorStyle, hasAvatar: Bool = false) {
        self.refs = refs
        self.style = style
        self.hasAvatar = hasAvatar
    }

    private var edge: Alignment { style == .me ? .trailing : .leading }

    /// Mirrors `MessageBubble`'s outer layout: own messages keep 32pt from
    /// the far edge; an avatar'd bubble starts after the avatar and its gap.
    private var leadingInset: CGFloat {
        if style == .me { return 32 }
        return hasAvatar ? SenderAvatar.diameter + 6 : 0
    }

    public var body: some View {
        let layout = ConversationPillLayout(refs: refs)
        PillFlowLayout(spacing: 6, trailing: style == .me) {
            ForEach(layout.visible) { ref in
                ConversationLinkPill(ref: ref)
            }
            if !layout.overflow.isEmpty {
                ConversationLinkOverflowPill(refs: layout.overflow)
            }
        }
        .frame(maxWidth: MessageBubbleMetrics.maxWidth, alignment: edge)
        .padding(.leading, leadingInset)
        .frame(maxWidth: .infinity, alignment: edge)
        .padding(.horizontal)
    }
}

/// Capsule chrome shared by a pill and the "+N" overflow.
private struct PillChrome: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
            .background(Capsule().fill(enabled ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.10)))
            .contentShape(Capsule())
    }
}

private struct ConversationLinkPill: View {
    let ref: ConversationLinkRef
    @Environment(\.conversationLinkHost) private var host
    @Environment(\.openConversation) private var openConversation

    var body: some View {
        let title = host?.title(for: ref.id)
        let label = ConversationLinkLabel.text(for: ref, title: title)
        let enabled = ConversationLinkLabel.isOpenable(title) && openConversation != nil
        Button {
            openConversation?(ref.id)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .imageScale(.small)
                Text(label)
            }
            .modifier(PillChrome(enabled: enabled))
            .frame(maxWidth: 240)
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel("Open conversation \(label)")
        .task(id: PillLoadKey(ids: [ref.id], generation: host?.generation ?? 0)) { await host?.load(ref.id) }
    }
}

private struct ConversationLinkOverflowPill: View {
    let refs: [ConversationLinkRef]
    @Environment(\.conversationLinkHost) private var host
    @Environment(\.openConversation) private var openConversation

    var body: some View {
        Menu {
            ForEach(refs) { ref in
                let title = host?.title(for: ref.id)
                Button(ConversationLinkLabel.text(for: ref, title: title)) {
                    openConversation?(ref.id)
                }
                .disabled(!ConversationLinkLabel.isOpenable(title) || openConversation == nil)
            }
        } label: {
            Text("+\(refs.count)")
                .modifier(PillChrome(enabled: true))
        }
        .modifier(OverflowMenuStyle())
        .accessibilityLabel("\(refs.count) more conversations")
        .task(id: PillLoadKey(ids: refs.map(\.id), generation: host?.generation ?? 0)) {
            for ref in refs { await host?.load(ref.id) }
        }
    }
}

/// What a pill's title load is keyed on: its conversations and the host's
/// lookup generation.
private struct PillLoadKey: Equatable {
    let ids: [String]
    let generation: Int
}

/// A Menu that draws its label as-is (the capsule), not a bordered pop-up
/// button. `.borderlessButton` on the Mac strips the label's background, so
/// both platforms use a plain-styled button menu.
private struct OverflowMenuStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// Left-to-right (or right-anchored) wrapping row: pills that don't fit on
/// a line wrap to the next rather than squeezing, so a narrow iPhone bubble
/// still shows whole capsules.
struct PillFlowLayout: Layout {
    let spacing: CGFloat
    /// Right-align each line (own messages).
    let trailing: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = trailing ? bounds.maxX - line.width : bounds.minX
            for (index, size) in line.items {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var items: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> [Line] {
        let maxWidth = width ?? .infinity
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, maxWidth)
            let needed = line.items.isEmpty ? size.width : line.width + spacing + size.width
            if !line.items.isEmpty, needed > maxWidth {
                lines.append(line)
                line = Line()
            }
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.items.append((index, size))
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}
