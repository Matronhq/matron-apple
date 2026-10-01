import Foundation
import CoreGraphics
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// Everything a text row's pixels depend on — the measurement cache compares
/// it by value, so a change to any field is a re-measure (spec: cache key
/// includes the content). Value-only and `Sendable`: text rows are measured
/// off the main thread.
struct TextRowContent: Equatable, Sendable {
    let itemID: String
    let body: String
    let isOwn: Bool
    let sendState: TimelineSendState
    let timestamp: Date
    /// Non-nil only in multi-sender rooms, never for own rows or the
    /// streaming placeholder (`TimelineItemView.avatarSender`).
    let avatarSender: String?
    /// "Me" or the sender's display name — the text view's VoiceOver label.
    let senderLabel: String
    /// Conversation links in the body → the pill row under the bubble.
    let pills: [ConversationLinkRef]
    /// What each pill on show draws. A pill shows its link's own text until
    /// the conversation's title loads, and the title is usually longer: four
    /// pills that fitted two lines then need four. Part of the content so a
    /// title arriving re-measures the row (tracker #3944 — the row kept its
    /// first height, and the pills spilled over the message above them and
    /// out of the bottom of the row).
    var pillLabels: [String] = []

    /// The mid-turn streaming overlay row (`eph:`), re-rendered per commit.
    var isStreaming: Bool { itemID.hasPrefix("eph:") }
}

/// A row rendered by existing SwiftUI views in a hosted cell: separators,
/// tool calls, diffs, ask-user / agent-chat / agent-spawn cards, markers,
/// subtask cards, images and files. Hosted views read their live
/// `ChatViewModel` state themselves (Observation) and self-report size
/// changes; the fields here are what the controller must re-measure for.
struct HostedRowContent: Equatable, Sendable {
    let row: TimelineRow
    /// Resolved child for a bridge "🔀 Subtask:" indicator → tappable card.
    let subtaskChild: SubChatSummary?
    let hasMultipleSenders: Bool
    /// `ChatViewModel.imagePixelSize(for:)` for image rows — flips from nil
    /// when the bytes land, so resolving an image re-measures that row only.
    let imagePixelSize: CGSize?
}

enum TimelineRowContent: Equatable, Sendable {
    case text(TextRowContent)
    case hosted(HostedRowContent)

    /// Scroll-anchor id: ITEM id for messages, row id for separators — the
    /// id space `pendingFocusID`, `rowAnchorIDs` and scroll memory use.
    var anchorID: String {
        switch self {
        case .text(let text): return text.itemID
        case .hosted(let hosted): return TimelineRowContentBuilder.anchorID(for: hosted.row)
        }
    }
}

/// The view-model state one build reads. `imagePixelSize` runs on the main
/// actor (the builder only runs there).
struct TimelineRowSource {
    let rows: [TimelineRow]
    let hasMultipleSenders: Bool
    let children: [SubChatSummary]
    let imagePixelSize: (URL) -> CGSize?
    /// `ConversationLinkHost.title(for:)` — nil until a pill has looked the
    /// conversation up.
    var pillTitle: (String) -> ConversationLinkTitle? = { _ in nil }
}

struct BuiltRows {
    let contents: [TimelineRowContent]
    /// Anchor ids seen more than once; the later copies were dropped (a
    /// diffable data source traps on duplicate identifiers).
    let droppedDuplicates: [String]
}

/// The body scans one build does per text message — the subtask-indicator
/// parse and the conversation-link scan — kept per row between builds. A
/// streaming reply syncs about once a frame; without this every sync
/// rescanned every body in the window (120–360 rows), when only the
/// streaming row had changed. An entry is reused while its message's body
/// and ownership and the room's sub-chats are unchanged; everything cheap
/// (send state, pill titles, image sizes, avatars) is still read fresh.
/// Main-actor only, like the builder.
final class TimelineRowScanMemo {
    struct Entry {
        let body: String
        let isOwn: Bool
        let subtaskChild: SubChatSummary?
        let pills: [ConversationLinkRef]
    }

    private(set) var entries: [String: Entry] = [:]
    private var children: [SubChatSummary] = []
    /// Rows scanned (not reused) by the last build — what tests pin.
    private(set) var lastScanCount = 0

    fileprivate func begin(children: [SubChatSummary]) {
        // A sub-chat appearing or renaming can resolve an indicator anywhere.
        if children != self.children {
            self.children = children
            entries.removeAll(keepingCapacity: true)
        }
        lastScanCount = 0
    }

    fileprivate func scans(for item: TimelineItem, body: String, children: [SubChatSummary]) -> Entry {
        if let entry = entries[item.id], entry.isOwn == item.isOwn, entry.body == body { return entry }
        lastScanCount += 1
        let child = TimelineRowContentBuilder.subtaskChild(for: item, children: children)
        let pills = child == nil
            ? ConversationLinkRefs.extract(from: body, cache: !item.isEphemeralStreamingPlaceholder)
            : []
        let entry = Entry(body: body, isOwn: item.isOwn, subtaskChild: child, pills: pills)
        entries[item.id] = entry
        return entry
    }

    /// Drop rows that left the window, so the memo stays window-sized.
    fileprivate func retain(only ids: Set<String>) {
        guard entries.count > ids.count else { return }
        entries = entries.filter { ids.contains($0.key) }
    }
}

enum TimelineRowContentBuilder {
    static func anchorID(for row: TimelineRow) -> String {
        if case .message(let item) = row { return item.id }
        return row.id
    }

    /// `memo` (the controller's, across syncs) reuses unchanged rows' body
    /// scans; without one every row is scanned.
    static func build(_ source: TimelineRowSource, memo: TimelineRowScanMemo? = nil) -> BuiltRows {
        let memo = memo ?? TimelineRowScanMemo()
        memo.begin(children: source.children)
        var seen = Set<String>()
        var contents: [TimelineRowContent] = []
        var dropped: [String] = []
        contents.reserveCapacity(source.rows.count)
        for row in source.rows {
            let id = anchorID(for: row)
            guard seen.insert(id).inserted else {
                dropped.append(id)
                continue
            }
            contents.append(content(for: row, source: source, memo: memo))
        }
        memo.retain(only: seen)
        return BuiltRows(contents: contents, droppedDuplicates: dropped)
    }

    private static func content(for row: TimelineRow, source: TimelineRowSource,
                                memo: TimelineRowScanMemo) -> TimelineRowContent {
        guard case .message(let item) = row else {
            return .hosted(HostedRowContent(row: row, subtaskChild: nil,
                                            hasMultipleSenders: source.hasMultipleSenders, imagePixelSize: nil))
        }
        var child: SubChatSummary?
        if case .text(let body, _) = item.kind {
            let scans = memo.scans(for: item, body: body, children: source.children)
            child = scans.subtaskChild
            if child == nil {
                let pills = scans.pills
                return .text(TextRowContent(
                    itemID: item.id,
                    body: body,
                    isOwn: item.isOwn,
                    sendState: item.sendState,
                    timestamp: item.timestamp,
                    avatarSender: TimelineItemView.avatarSender(for: item, hasMultipleSenders: source.hasMultipleSenders),
                    senderLabel: item.isOwn ? "Me" : TimelineItemView.displayName(for: item.sender),
                    pills: pills,
                    pillLabels: ConversationPillLayout(refs: pills).visible.map {
                        ConversationLinkLabel.text(for: $0, title: source.pillTitle($0.id))
                    }))
            }
        }
        var pixelSize: CGSize?
        if case .image(let url?, _, _, _) = item.kind { pixelSize = source.imagePixelSize(url) }
        return .hosted(HostedRowContent(row: row, subtaskChild: child,
                                        hasMultipleSenders: source.hasMultipleSenders, imagePixelSize: pixelSize))
    }

    /// The child sub-chat a bridge subtask-indicator message refers to, or
    /// nil when `item` isn't an indicator or no child matches (the row then
    /// renders as the plain text message it always was).
    fileprivate static func subtaskChild(for item: TimelineItem, children: [SubChatSummary]) -> SubChatSummary? {
        guard case .text(let body, _) = item.kind, !item.isOwn,
              let description = SubChatStripViewModel.subtaskDescription(fromMessageBody: body)
        else { return nil }
        return SubChatStripViewModel.resolveSubtaskTarget(description: description, among: children)
    }
}
