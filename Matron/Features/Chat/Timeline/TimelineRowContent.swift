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
}

struct BuiltRows {
    let contents: [TimelineRowContent]
    /// Anchor ids seen more than once; the later copies were dropped (a
    /// diffable data source traps on duplicate identifiers).
    let droppedDuplicates: [String]
}

enum TimelineRowContentBuilder {
    static func anchorID(for row: TimelineRow) -> String {
        if case .message(let item) = row { return item.id }
        return row.id
    }

    static func build(_ source: TimelineRowSource) -> BuiltRows {
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
            contents.append(content(for: row, source: source))
        }
        return BuiltRows(contents: contents, droppedDuplicates: dropped)
    }

    private static func content(for row: TimelineRow, source: TimelineRowSource) -> TimelineRowContent {
        guard case .message(let item) = row else {
            return .hosted(HostedRowContent(row: row, subtaskChild: nil,
                                            hasMultipleSenders: source.hasMultipleSenders, imagePixelSize: nil))
        }
        let child = subtaskChild(for: item, children: source.children)
        if case .text(let body, _) = item.kind, child == nil {
            return .text(TextRowContent(
                itemID: item.id,
                body: body,
                isOwn: item.isOwn,
                sendState: item.sendState,
                timestamp: item.timestamp,
                avatarSender: TimelineItemView.avatarSender(for: item, hasMultipleSenders: source.hasMultipleSenders),
                senderLabel: item.isOwn ? "Me" : TimelineItemView.displayName(for: item.sender),
                pills: ConversationLinkRefs.extract(from: body, cache: !item.isEphemeralStreamingPlaceholder)))
        }
        var pixelSize: CGSize?
        if case .image(let url?, _, _, _) = item.kind { pixelSize = source.imagePixelSize(url) }
        return .hosted(HostedRowContent(row: row, subtaskChild: child,
                                        hasMultipleSenders: source.hasMultipleSenders, imagePixelSize: pixelSize))
    }

    /// Same resolution as the SwiftUI path's `TimelineListContent.subtaskChild(for:)`.
    private static func subtaskChild(for item: TimelineItem, children: [SubChatSummary]) -> SubChatSummary? {
        guard case .text(let body, _) = item.kind, !item.isOwn,
              let description = SubChatStripViewModel.subtaskDescription(fromMessageBody: body)
        else { return nil }
        return SubChatStripViewModel.resolveSubtaskTarget(description: description, among: children)
    }
}
