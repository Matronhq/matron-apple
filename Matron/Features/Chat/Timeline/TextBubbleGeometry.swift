import CoreGraphics
import MatronDesignSystem

/// UIKit twin of `MessageBubble` (+ `TimelineItemView`'s pill row and
/// own-message send-state VStack). Every number here is read off the
/// SwiftUI source so the two timelines lay a message out identically:
///   - row: `.padding(.horizontal)` = 16 each side
///   - own: `.padding(.leading, 32)`; bot with avatar: avatar 24 + gap 6
///   - bubble: `.padding(.horizontal, 12).padding(.vertical, 8)`, capped
///     at `MessageBubbleMetrics.maxWidth`, corner radius 8
///   - content + time: `HStack(alignment: .lastTextBaseline, spacing: 6)`
///   - pills: `VStack(spacing: 4)` under the bubble, full row width
///   - send state: `VStack(alignment: .trailing, spacing: 2)`
enum TextBubbleGeometry {
    static let rowPadding: CGFloat = 16
    static let ownLeadingInset: CGFloat = 32
    static let avatarDiameter: CGFloat = SenderAvatar.diameter
    static let avatarGap: CGFloat = 6
    static let bubblePaddingH: CGFloat = 12
    static let bubblePaddingV: CGFloat = 8
    static let timestampGap: CGFloat = 6
    static let maxBubbleWidth: CGFloat = MessageBubbleMetrics.maxWidth
    static let pillsGap: CGFloat = 4
    static let sendStateGap: CGFloat = 2
    static let cornerRadius: CGFloat = 8

    struct Timestamp: Equatable {
        let size: CGSize
        /// The time font's ascender — its baseline below the label top.
        let ascent: CGFloat
    }

    /// The message's content column measured at a wrap width.
    struct Content: Equatable {
        let size: CGSize
        let lastBaseline: CGFloat
        /// Content-column coordinates.
        let segmentFrames: [CGRect]
    }

    private static func leadingInset(isOwn: Bool, hasAvatar: Bool) -> CGFloat {
        if isOwn { return ownLeadingInset }
        return hasAvatar ? avatarDiameter + avatarGap : 0
    }

    /// The width the message text wraps at inside a row `rowWidth` wide.
    static func wrapWidth(rowWidth: CGFloat, isOwn: Bool, hasAvatar: Bool, timestampWidth: CGFloat) -> CGFloat {
        let inner = rowWidth - 2 * rowPadding
        let bubbleMax = min(inner - leadingInset(isOwn: isOwn, hasAvatar: hasAvatar), maxBubbleWidth)
        return max(0, bubbleMax - 2 * bubblePaddingH - timestampGap - timestampWidth)
    }

    static func layout(rowWidth: CGFloat, isOwn: Bool, hasAvatar: Bool, timestamp: Timestamp,
                       content measure: (CGFloat) -> Content,
                       pillsHeight: ((CGFloat) -> CGFloat)?, sendStateHeight: CGFloat?) -> TextRowLayout {
        let showsAvatar = hasAvatar && !isOwn
        let wrap = wrapWidth(rowWidth: rowWidth, isOwn: isOwn, hasAvatar: showsAvatar,
                             timestampWidth: timestamp.size.width)
        let content = measure(wrap)

        // `.lastTextBaseline`: the content's last baseline and the time's
        // baseline share one line; whichever sits lower sets the offset.
        let contentTop: CGFloat
        let timestampTop: CGFloat
        if content.lastBaseline >= timestamp.ascent {
            contentTop = 0
            timestampTop = content.lastBaseline - timestamp.ascent
        } else {
            contentTop = timestamp.ascent - content.lastBaseline
            timestampTop = 0
        }
        let stackHeight = max(contentTop + content.size.height, timestampTop + timestamp.size.height)
        let bubbleWidth = 2 * bubblePaddingH + content.size.width + timestampGap + timestamp.size.width
        let bubbleHeight = 2 * bubblePaddingV + stackHeight
        let bubbleX = isOwn
            ? rowWidth - rowPadding - bubbleWidth
            : rowPadding + leadingInset(isOwn: false, hasAvatar: showsAvatar)
        let bubble = CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: bubbleHeight)

        let segments = content.segmentFrames.map {
            $0.offsetBy(dx: bubblePaddingH, dy: bubblePaddingV + contentTop)
        }
        let time = CGRect(x: bubblePaddingH + content.size.width + timestampGap, y: bubblePaddingV + timestampTop,
                          width: timestamp.size.width, height: timestamp.size.height)
        let avatar = showsAvatar
            ? CGRect(x: rowPadding, y: bubble.maxY - avatarDiameter, width: avatarDiameter, height: avatarDiameter)
            : nil

        var bottom = bubble.maxY
        var pills: CGRect?
        if let pillsHeight {
            let frame = CGRect(x: 0, y: bottom + pillsGap, width: rowWidth, height: pillsHeight(rowWidth))
            pills = frame
            bottom = frame.maxY
        }
        var sendState: CGRect?
        if let sendStateHeight {
            let frame = CGRect(x: rowPadding, y: bottom + sendStateGap,
                               width: rowWidth - 2 * rowPadding, height: sendStateHeight)
            sendState = frame
            bottom = frame.maxY
        }
        return TextRowLayout(rowHeight: ceil(bottom), bubbleFrame: bubble, segmentFrames: segments,
                             timestampFrame: time, avatarFrame: avatar, pillsFrame: pills, sendStateFrame: sendState)
    }
}

/// Every frame of one laid-out text row (cell coordinates unless noted).
struct TextRowLayout: Equatable {
    var rowHeight: CGFloat
    var bubbleFrame: CGRect
    /// Bubble coordinates.
    var segmentFrames: [CGRect]
    /// Bubble coordinates.
    var timestampFrame: CGRect
    var avatarFrame: CGRect?
    var pillsFrame: CGRect?
    var sendStateFrame: CGRect?

    /// Test/fake convenience: a row of `height` with no content frames.
    static func fixed(height: CGFloat) -> TextRowLayout {
        TextRowLayout(rowHeight: height, bubbleFrame: .zero, segmentFrames: [], timestampFrame: .zero,
                      avatarFrame: nil, pillsFrame: nil, sendStateFrame: nil)
    }
}
