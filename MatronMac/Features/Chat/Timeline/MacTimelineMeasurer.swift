import AppKit
import SwiftUI
import MatronChat
import MatronModels
import MatronDesignSystem

/// Everything a text row view draws: the content, its rendered markdown, the
/// laid-out frames and the timestamp string. Built by
/// `MacTimelineMeasurer.measureText` — the same numbers size the table row and
/// position its subviews, so the two can never disagree.
struct MacTextRowRender {
    let content: TextRowContent
    let rendered: MarkdownAttributed.Rendered
    /// Row coordinates; `segmentFrames[0]` is the body frame in the bubble.
    let layout: TextRowLayout
    /// `Date.FormatStyle.dateTime.hour().minute()`, as SwiftUI's
    /// `Text(_:format:)` in `MessageBubble` renders it.
    let timestampText: String
}

/// One row's measured height: a native text row carries its whole render, a
/// hosted SwiftUI row only its height.
enum MacRowMeasurement {
    case text(MacTextRowRender)
    case hosted(CGFloat)

    var height: CGFloat {
        switch self {
        case .text(let render): return render.layout.rowHeight
        case .hosted(let height): return height
        }
    }
}

/// Row measurements keyed by (room, row id, width). A hit also requires the
/// stored content to EQUAL the asked-for content — any change to what a row
/// draws (body, send state, pills, image size…) is a miss and a re-measure.
/// `NSCache` is thread-safe, so off-main text measurement can store directly.
final class MacTimelineMeasureCache {
    static let shared = MacTimelineMeasureCache(countLimit: 4000)

    private final class Entry {
        let content: TimelineRowContent
        let measurement: MacRowMeasurement
        init(content: TimelineRowContent, measurement: MacRowMeasurement) {
            self.content = content
            self.measurement = measurement
        }
    }

    private let cache = NSCache<NSString, Entry>()

    init(countLimit: Int) {
        cache.countLimit = countLimit
    }

    func measurement(roomID: String, content: TimelineRowContent, width: CGFloat) -> MacRowMeasurement? {
        guard let entry = cache.object(forKey: Self.key(roomID: roomID, content: content, width: width)),
              entry.content == content
        else { return nil }
        return entry.measurement
    }

    func store(_ m: MacRowMeasurement, roomID: String, content: TimelineRowContent, width: CGFloat) {
        cache.setObject(Entry(content: content, measurement: m),
                        forKey: Self.key(roomID: roomID, content: content, width: width))
    }

    /// Test seam: what memory pressure does to the `NSCache`.
    func removeAllForTesting() {
        cache.removeAllObjects()
    }

    #if DEBUG
    /// Why `measurement` missed (perf follow-ups D0): no entry for the key,
    /// or which part of the stored content differs from `content`.
    /// A new field on `TextRowContent` / `HostedRowContent` needs a matching line here.
    func missReason(roomID: String, content: TimelineRowContent, width: CGFloat) -> String {
        guard let entry = cache.object(forKey: Self.key(roomID: roomID, content: content, width: width)) else {
            return "absent"
        }
        switch (entry.content, content) {
        case (.hosted(let old), .hosted(let new)):
            var parts: [String] = []
            if old.row != new.row {
                if case .message(let a) = old.row, case .message(let b) = new.row {
                    if a.kind != b.kind { parts.append("item.kind") }
                    if a.timestamp != b.timestamp { parts.append("item.timestamp") }
                    if a.sendState != b.sendState { parts.append("item.sendState") }
                    if a.sender != b.sender { parts.append("item.sender") }
                    if a.isOwn != b.isOwn || a.inReplyToEventID != b.inReplyToEventID { parts.append("item.other") }
                    if parts.isEmpty { parts.append("item.?") }
                } else {
                    parts.append("row")
                }
            }
            if old.subtaskChild != new.subtaskChild { parts.append("subtaskChild") }
            if old.hasMultipleSenders != new.hasMultipleSenders { parts.append("hasMultipleSenders") }
            if old.imagePixelSize != new.imagePixelSize { parts.append("imagePixelSize") }
            return parts.isEmpty ? "equal?" : parts.joined(separator: "+")
        case (.text(let old), .text(let new)):
            var parts: [String] = []
            if old.body != new.body { parts.append("body") }
            if old.timestamp != new.timestamp { parts.append("timestamp") }
            if old.sendState != new.sendState { parts.append("sendState") }
            if old.avatarSender != new.avatarSender || old.senderLabel != new.senderLabel { parts.append("sender") }
            if old.pills != new.pills { parts.append("pills") }
            if old.pillLabels != new.pillLabels { parts.append("pillLabels") }
            if old.isOwn != new.isOwn { parts.append("isOwn") }
            return parts.isEmpty ? "equal?" : parts.joined(separator: "+")
        default:
            return "kind"
        }
    }
    #endif

    private static func key(roomID: String, content: TimelineRowContent, width: CGFloat) -> NSString {
        "\(roomID)\u{1F}\(content.anchorID)\u{1F}\(width)" as NSString
    }
}

/// Measures timeline rows for the AppKit table. Text rows go through the
/// shared `TextBubbleGeometry` (the twin of SwiftUI's `MessageBubble`), with
/// the two SwiftUI pieces it can't compute — the conversation-link pill row
/// and the send-state footer — sized by hosting the real views. Every other
/// row is hosted SwiftUI, sized by one reusable `NSHostingView`.
@MainActor final class MacTimelineMeasurer {
    private let hostedRow: (HostedRowContent) -> AnyView
    /// The host the pills on screen read their titles from: sizing a pill
    /// row without it measures every pill at its link's own text, however
    /// long the loaded title it draws.
    private let conversationLinkHost: () -> ConversationLinkHost?
    /// One hosting view reused for every hosted measurement.
    private lazy var sizer = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
    /// Send-state footer heights, per glyph kind and width.
    private var sendStateHeights: [String: CGFloat] = [:]
    /// Perf follow-ups S5: the streaming row's body size, kept across its
    /// commits by item id so each re-lays out only from its first changed
    /// paragraph. Main actor only, like the whole measurer: the background
    /// precompute goes through the static `measureText` and never sees
    /// these (a streaming row it measures is measured in full, and the
    /// sizer diffs its next commit against what IT last measured, so the
    /// skipped commit costs nothing but a longer edit).
    private var streamingSizers: [String: MarkdownAttributed.StreamingSizer] = [:]

    init(hostedRow: @escaping (HostedRowContent) -> AnyView,
         conversationLinkHost: @escaping () -> ConversationLinkHost? = { nil }) {
        self.hostedRow = hostedRow
        self.conversationLinkHost = conversationLinkHost
    }

    /// Off-main safe (pure + Rendered's locks) with the default `bodySize`.
    /// - Parameter bodySize: the body's size at a wrap width;
    ///   `Rendered.size(width:)` unless the caller has an equal, cheaper
    ///   answer (`measureStreaming`).
    nonisolated static func measureText(
        _ content: TextRowContent, width: CGFloat, pillsHeight: CGFloat?, sendStateHeight: CGFloat?,
        bodySize: (MarkdownAttributed.Rendered, CGFloat) -> CGSize = { $0.size(width: $1) }
    ) -> MacTextRowRender {
        let rendered = MarkdownAttributed.rendered(for: content.body, style: .chat, cache: !content.isStreaming)
        let timestampText = content.timestamp.formatted(.dateTime.hour().minute())
        // `MessageBubble`'s time: `Text(…).font(.caption2).fixedSize()`.
        let font = NSFont.preferredFont(forTextStyle: .caption2)
        // Both rounded up to whole points, as SwiftUI lays the time out:
        // `Text` reports its size ceiled (measured 28 × 13 for "22:13",
        // where `size()` gives 27.34 × 13; the width sets the message's wrap
        // width), and its baseline sits 10 pt down, not at the 9.67 pt
        // ascender — the bubble's stack is body + 3 (13 − 10), not
        // body + 3.33, which left every row 1 pt taller than SwiftUI's.
        let measured = NSAttributedString(string: timestampText, attributes: [.font: font]).size()
        let timestampSize = CGSize(width: ceil(measured.width), height: ceil(measured.height))
        let timestamp = TextBubbleGeometry.Timestamp(size: timestampSize, ascent: ceil(font.ascender))
        let layout = TextBubbleGeometry.layout(
            rowWidth: width, isOwn: content.isOwn, hasAvatar: content.avatarSender != nil,
            timestamp: timestamp,
            content: { wrap in
                let size = bodySize(rendered, wrap)
                // The body's last baseline is its BOTTOM, not the last line's
                // baseline: SwiftUI reports no text baseline for the
                // `SelectableMessageText` representable, so `MessageBubble`'s
                // `.lastTextBaseline` HStack falls back to the view's bottom.
                // Measured (2026-09-28, wrap 400): the HStack is always body
                // height + 3 ("Hi" 17 → 20, a table 79 → 82, identical to the
                // body-bottom case + the time's 13 − 9.67 descent), while
                // the last line's true baseline (14 for "Hi", 46 for the
                // table) left every row 2–3 pt short.
                return .init(size: size, lastBaseline: size.height,
                             segmentFrames: [CGRect(origin: .zero, size: size)])
            },
            pillsHeight: content.pills.isEmpty ? nil : pillsHeight.map { height in { _ in height } },
            sendStateHeight: content.isOwn && content.sendState != .sent ? sendStateHeight : nil)
        return MacTextRowRender(content: content, rendered: rendered, layout: layout, timestampText: timestampText)
    }

    func measure(_ content: TimelineRowContent, width: CGFloat) -> MacRowMeasurement {
        switch content {
        case .text(let text):
            let pills = text.pills.isEmpty
                ? nil
                : pillsHeight(text.pills, isOwn: text.isOwn, hasAvatar: text.avatarSender != nil, width: width)
            let sendState = text.isOwn && text.sendState != .sent
                ? sendStateHeight(width: width, state: text.sendState)
                : nil
            if text.isStreaming {
                return .text(measureStreaming(text, width: width, pillsHeight: pills, sendStateHeight: sendState))
            }
            return .text(Self.measureText(text, width: width, pillsHeight: pills, sendStateHeight: sendState))
        case .hosted(let hosted):
            return .hosted(hostedHeight(hosted, width: width))
        }
    }

    /// `measureText` for the streaming row, with the body sized by its
    /// `StreamingSizer` (created on first use): the same render and layout,
    /// laid out incrementally.
    func measureStreaming(_ text: TextRowContent, width: CGFloat,
                          pillsHeight: CGFloat?, sendStateHeight: CGFloat?) -> MacTextRowRender {
        let sizer: MarkdownAttributed.StreamingSizer
        if let kept = streamingSizers[text.itemID] {
            sizer = kept
        } else {
            sizer = MarkdownAttributed.StreamingSizer()
            streamingSizers[text.itemID] = sizer
        }
        return Self.measureText(text, width: width, pillsHeight: pillsHeight, sendStateHeight: sendStateHeight,
                                bodySize: { rendered, wrap in sizer.size(of: rendered, width: wrap) })
    }

    /// Drops the sizer of every row not in `ids` — the ids of the rows
    /// streaming now: a finished reply is a new (non-streaming) row id, so
    /// its sizer and both TextKit stacks go with the `eph:` row.
    func keepStreamingSizers(for ids: Set<String>) {
        guard streamingSizers.keys.contains(where: { !ids.contains($0) }) else { return }
        streamingSizers = streamingSizers.filter { ids.contains($0.key) }
    }

    #if DEBUG
    /// Test seam: the item ids holding a streaming sizer.
    var streamingSizerIDsForTesting: Set<String> { Set(streamingSizers.keys) }
    /// Test seam: the sizer measuring `id`, if any.
    func streamingSizerForTesting(_ id: String) -> MarkdownAttributed.StreamingSizer? { streamingSizers[id] }
    #endif

    /// The conversation-link pill row under a bubble, as `MacTimelineItemView`
    /// lays it out (full row width), with the titles the host holds now —
    /// the ones the row's `pillLabels` were built from.
    func pillsHeight(_ refs: [ConversationLinkRef], isOwn: Bool, hasAvatar: Bool, width: CGFloat) -> CGFloat {
        fittingHeight(AnyView(ConversationLinkPillRow(refs: refs, style: isOwn ? .me : .bot, hasAvatar: hasAvatar)
                          .environment(\.conversationLinkHost, conversationLinkHost())),
                      width: width)
    }

    /// The own-message send-state footer, as `MacTimelineItemView` lays it
    /// out (`.padding(.horizontal)` inside the row). `state` defaults to
    /// `.sending`; the glyph (not a `.failed` reason) decides the height, so
    /// heights are memoised per glyph kind and width.
    func sendStateHeight(width: CGFloat, state: TimelineSendState = .sending) -> CGFloat {
        let glyph = SendStateGlyph.from(state)
        let kind: String
        switch glyph {
        case .sending: kind = "sending"
        case .sent: kind = "sent"
        case .queued: kind = "queued"
        case .failed: kind = "failed"
        }
        let key = "\(kind)|\(width)"
        if let hit = sendStateHeights[key] { return hit }
        let height = fittingHeight(AnyView(SendStateIndicator(state: glyph).padding(.horizontal)), width: width)
        sendStateHeights[key] = height
        return height
    }

    /// A hosted SwiftUI row's height at `width`, via the reusable sizer.
    func hostedHeight(_ content: HostedRowContent, width: CGFloat) -> CGFloat {
        fittingHeight(hostedRow(content), width: width)
    }

    private func fittingHeight(_ view: AnyView, width: CGFloat) -> CGFloat {
        sizer.rootView = AnyView(view.frame(width: width))
        return sizer.fittingSize.height
    }
}
