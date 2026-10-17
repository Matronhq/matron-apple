import AppKit
import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronModels

/// The AppKit sidebar's chat row: the native twin of `MacChatRow`, drawn by
/// hand so its height is fixed and known up front, and a content change
/// costs a redraw of one row rather than a SwiftUI graph per row.
///
/// Same parts, fonts, colours and spacing as `MacChatRow`:
///
/// - the title line (14 pt): the `A:bc` session tag (box letter in the
///   box's hue, the session short in primary) or a room's `A↔B` tag, then
///   the title, truncated as one line;
/// - the second line (12 pt, secondary): the snippet (a space when empty,
///   which SwiftUI also lays out), then `·` and the "5m" time, which never
///   truncates;
/// - trailing, 4 pt apart: the bell-slash (notifications off), "New", the
///   orange needs-you pill and the accent unread pill;
/// - the hover tint (grey at 8%, 6 pt corners) behind the content.
///
/// `MacChatListCellSnapshotTests` holds it to `MacChatRow`'s geometry, light
/// and dark, on the same fixtures.
final class MacChatListCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebar.chat")

    /// Measured from today's SwiftUI sidebar rows (`MacChatRow` in a
    /// `.sidebar` `List`): 51 pt when the row shows a snippet and a time,
    /// whose `·` is set in the 13 pt body font. Fixed here for every row.
    static let rowHeight: CGFloat = 51

    enum Metrics {
        /// The content's inset in the cell, each side (`MacChatRow`'s
        /// horizontal padding).
        static let padding: CGFloat = 4
        /// The content block (both lines with their vertical padding),
        /// centred in the row; the hover tint fills it.
        static let contentHeight: CGFloat = 43
        /// The lines' tops in the content block.
        static let titleTop: CGFloat = 4
        static let titleLineHeight: CGFloat = 17
        static let detailTop: CGFloat = 23
        static let detailLineHeight: CGFloat = 16
        /// Between the text column and the badges.
        static let columnSpacing: CGFloat = 8
        /// Between the badges, and between the snippet, `·` and the time.
        static let itemSpacing: CGFloat = 4
        static let hoverCornerRadius: CGFloat = 6
    }

    enum Fonts {
        static let title = NSFont.systemFont(ofSize: 14)
        static let titleTag = NSFont.systemFont(ofSize: 14, weight: .semibold)
        static let detail = NSFont.systemFont(ofSize: 12)
        /// The `·` has no font of its own in `MacChatRow`: the body font.
        static let dot = NSFont.systemFont(ofSize: 13)
        static let badge = NSFont.systemFont(ofSize: 10, weight: .semibold)
        static let silencedIconSize: CGFloat = 11
    }

    /// The row shown, and when its time was formatted.
    private(set) var row: MacSidebarChat?
    private(set) var timeText: String?
    private(set) var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Shows `row`, its time as of `now`, and says whether anything
    /// changed. Idempotent: an unchanged row and time draw nothing.
    @discardableResult
    func configure(_ row: MacSidebarChat, now: Date) -> Bool {
        let time = row.summary.lastActivity.map { RelativeMinuteTimeView.format($0, now: now) }
        guard row != self.row || time != timeText else { return false }
        self.row = row
        timeText = time
        needsDisplay = true
        return true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        // A cell reused (or scrolled) under a still pointer gets no
        // `mouseEntered`: read where the pointer is now.
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isHovered = NSApp.isActive && visibleRect.contains(point)
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Hover from outside (tests and the screenshot harness).
    func setHoveredForTesting(_ hovered: Bool) { isHovered = hovered }

    // MARK: Layout

    /// Where each part goes for `row` in a cell of `size`: the drawing and
    /// the tests read the same frames.
    struct Layout: Equatable {
        var hover: NSRect
        var title: NSRect
        var snippet: NSRect?
        var dot: NSRect?
        var time: NSRect?
        /// Trailing parts, leading to trailing.
        var badges: [(kind: Badge, frame: NSRect)]

        static func == (lhs: Layout, rhs: Layout) -> Bool {
            lhs.hover == rhs.hover && lhs.title == rhs.title && lhs.snippet == rhs.snippet && lhs.dot == rhs.dot
                && lhs.time == rhs.time && lhs.badges.map(\.kind) == rhs.badges.map(\.kind)
                && lhs.badges.map(\.frame) == rhs.badges.map(\.frame)
        }
    }

    enum Badge: Equatable {
        case silenced
        case new
        case needsYou(String)
        case unread(String)
    }

    /// The trailing parts `row` shows, leading to trailing (`MacChatRow`'s
    /// order).
    static func badges(for row: MacSidebarChat) -> [Badge] {
        var badges: [Badge] = []
        if row.isSilenced { badges.append(.silenced) }
        if row.isNew { badges.append(.new) }
        let needs = row.summary.needsUserCount
        if needs > 0 { badges.append(.needsYou(needs > 99 ? "99+" : "\(needs)")) }
        let unread = row.summary.unreadCount
        if unread > 0 { badges.append(.unread(unread > 99 ? "99+" : "\(unread)")) }
        return badges
    }

    static func layout(for row: MacSidebarChat, time: String?, title: NSAttributedString, in size: NSSize) -> Layout {
        let left = Metrics.padding
        let right = size.width - Metrics.padding
        let top = ((size.height - Metrics.contentHeight) / 2).rounded(.down)
        let hover = NSRect(x: 0, y: top, width: size.width, height: Metrics.contentHeight)

        // Trailing parts, laid out from the right, centred on the content.
        var badges: [(kind: Badge, frame: NSRect)] = []
        var x = right
        let centerY = top + Metrics.contentHeight / 2
        for badge in Self.badges(for: row).reversed() {
            let badgeSize = Self.size(of: badge)
            x -= badgeSize.width
            let frame = NSRect(x: x, y: (centerY - badgeSize.height / 2).rounded(), width: badgeSize.width,
                               height: badgeSize.height)
            badges.insert((badge, frame), at: 0)
            x -= Metrics.itemSpacing
        }
        // `MacChatRow`'s `Spacer(minLength: 0)` sits between the text and
        // the badges, so its HStack's spacing comes twice.
        let textRight = (badges.first?.frame.minX ?? right) - Metrics.columnSpacing * 2
        let textWidth = max(0, textRight - left)

        let titleWidth = fittedWidth(title, in: textWidth)
        let titleFrame = NSRect(x: left, y: top + Metrics.titleTop, width: titleWidth,
                                height: Metrics.titleLineHeight)

        // The second line: snippet (a space when empty), `·` beside a
        // snippet, then the time; the time keeps its width.
        let lineTop = top + Metrics.detailTop
        let snippetText = row.summary.snippet.isEmpty ? " " : row.summary.snippet
        let snippetString = detailString(snippetText, color: .secondaryLabelColor)
        var snippet: NSRect?
        var dot: NSRect?
        var timeFrame: NSRect?
        if let time {
            let timeWidth = fittedWidth(detailString(time, color: .secondaryLabelColor), in: .greatestFiniteMagnitude)
            let dotWidth = row.summary.snippet.isEmpty
                ? 0 : fittedWidth(dotString(color: .secondaryLabelColor), in: .greatestFiniteMagnitude)
            let fixed = timeWidth + Metrics.itemSpacing + (dotWidth > 0 ? dotWidth + Metrics.itemSpacing : 0)
            // A truncated snippet is as wide as what it draws, so the `·`
            // and the time follow its ellipsis (as SwiftUI's `Text` does).
            let snippetWidth = fittedWidth(snippetString, in: max(0, textWidth - fixed))
            snippet = NSRect(x: left, y: lineTop, width: snippetWidth, height: Metrics.detailLineHeight)
            var cursor = left + snippetWidth + Metrics.itemSpacing
            if dotWidth > 0 {
                dot = NSRect(x: cursor, y: lineTop, width: dotWidth, height: Metrics.detailLineHeight)
                cursor += dotWidth + Metrics.itemSpacing
            }
            timeFrame = NSRect(x: cursor, y: lineTop, width: min(timeWidth, max(0, textRight - cursor)),
                               height: Metrics.detailLineHeight)
        } else {
            snippet = NSRect(x: left, y: lineTop, width: fittedWidth(snippetString, in: textWidth),
                             height: Metrics.detailLineHeight)
        }
        return Layout(hover: hover, title: titleFrame, snippet: snippet, dot: dot, time: timeFrame, badges: badges)
    }

    // MARK: Badges

    static let badgeHorizontalPadding: CGFloat = 6
    static let badgeMinWidth: CGFloat = 18
    /// Between the needs-you glyph and its count (`Label`'s spacing).
    static let badgeIconSpacing: CGFloat = 7
    /// The pills' height (SwiftUI sets the 10 pt text on a 13 pt line).
    static let badgeHeight: CGFloat = 17

    static func size(of badge: Badge) -> NSSize {
        switch badge {
        case .silenced:
            let image = silencedImage
            return NSSize(width: ceil(image?.size.width ?? 12), height: ceil(image?.size.height ?? 12))
        case .new:
            return pillSize(text: "New", icon: false)
        case .needsYou(let text):
            return pillSize(text: text, icon: true)
        case .unread(let text):
            return pillSize(text: text, icon: false)
        }
    }

    private static func pillSize(text: String, icon: Bool) -> NSSize {
        let textSize = badgeString(text, color: .white).size()
        var width = ceil(textSize.width)
        if icon, let image = needsYouImage { width += ceil(image.size.width) + badgeIconSpacing }
        return NSSize(width: max(badgeMinWidth, width + badgeHorizontalPadding * 2), height: badgeHeight)
    }

    private static let silencedImage: NSImage? = NSImage(systemSymbolName: "bell.slash",
                                                         accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Fonts.silencedIconSize, weight: .regular))

    private static let needsYouImage: NSImage? = NSImage(systemSymbolName: "questionmark.circle.fill",
                                                         accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))

    // MARK: Text

    private static func paragraph() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }

    private static let truncating = paragraph()

    static func detailString(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Fonts.detail, .foregroundColor: color,
                                                      .paragraphStyle: truncating])
    }

    static func dotString(color: NSColor) -> NSAttributedString {
        NSAttributedString(string: "·", attributes: [.font: Fonts.dot, .foregroundColor: color])
    }

    static func badgeString(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Fonts.badge, .foregroundColor: color])
    }

    /// The title line as `MacChatRow` composes it: the room tag, else the
    /// session tag, else the bare title.
    static func titleString(for summary: ChatSummary, isDark: Bool, primary: NSColor,
                            secondary: NSColor) -> NSAttributedString {
        let line = NSMutableAttributedString()
        func append(_ text: String, _ color: NSColor, _ font: NSFont = Fonts.title) {
            line.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        let scheme: ColorScheme = isDark ? .dark : .light
        let letters = summary.roomBoxShorts, names = summary.roomBoxNames
        if letters.count >= 2, letters.count == names.count {
            for (index, (letter, name)) in zip(letters, names).enumerated() {
                if index > 0 { append(letters.count == 2 ? "↔" : ",", secondary) }
                append(letter, tint(for: name, scheme), Fonts.titleTag)
            }
            if let short = summary.sessionShort {
                append(":", secondary)
                append(short, primary)
            }
            append(" ", primary)
            append(SessionTag.titleBesideRoomTag(summary.title), primary)
        } else if summary.boxShort != nil || summary.sessionShort != nil {
            if let letter = summary.boxShort {
                append(letter, summary.boxName.map { tint(for: $0, scheme) } ?? secondary, Fonts.titleTag)
            }
            if let short = summary.sessionShort {
                if summary.boxShort != nil { append(":", secondary) }
                append(short, primary)
            }
            append(" ", primary)
            append(summary.title, primary)
        } else {
            append(summary.title, primary)
        }
        line.addAttribute(.paragraphStyle, value: truncating, range: NSRange(location: 0, length: line.length))
        return line
    }

    private static var tints: [String: NSColor] = [:]

    /// `BoxChip.textTint`, as an `NSColor` for one scheme.
    static func tint(for name: String, _ scheme: ColorScheme) -> NSColor {
        let key = "\(scheme == .dark ? "d" : "l"):\(name)"
        if let cached = tints[key] { return cached }
        let color = NSColor(BoxChip.textTint(for: name, in: scheme))
        tints[key] = color
        return color
    }

    // MARK: Drawing

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let emphasized = backgroundStyle == .emphasized
        let primary: NSColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor = emphasized
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        let title = Self.titleString(for: row.summary, isDark: isDark, primary: primary, secondary: secondary)
        let layout = Self.layout(for: row, time: timeText, title: title, in: bounds.size)

        if isHovered {
            NSColor.systemGray.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: layout.hover, xRadius: Metrics.hoverCornerRadius,
                         yRadius: Metrics.hoverCornerRadius).fill()
        }

        Self.drawLine(title, in: layout.title, lineHeight: Metrics.titleLineHeight)
        if let frame = layout.snippet {
            let text = row.summary.snippet.isEmpty ? " " : row.summary.snippet
            Self.drawLine(Self.detailString(text, color: secondary), in: frame, lineHeight: Metrics.detailLineHeight)
        }
        if let frame = layout.dot {
            Self.drawLine(Self.dotString(color: secondary), in: frame, lineHeight: Metrics.detailLineHeight)
        }
        if let frame = layout.time, let timeText {
            Self.drawLine(Self.detailString(timeText, color: secondary), in: frame,
                          lineHeight: Metrics.detailLineHeight)
        }
        for (badge, frame) in layout.badges {
            draw(badge, in: frame, secondary: secondary)
        }
    }

    /// `text` as one line, truncated with an ellipsis to `width`.
    static func line(_ text: NSAttributedString, in width: CGFloat) -> CTLine {
        let line = CTLineCreateWithAttributedString(text)
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > width else { return line }
        let attributes = text.length > 0 ? text.attributes(at: text.length - 1, effectiveRange: nil) : [:]
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attributes))
        return CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis)
            ?? CTLineCreateWithAttributedString(NSAttributedString())
    }

    /// The width `text` draws in at most `width`, in whole points.
    static func fittedWidth(_ text: NSAttributedString, in width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(width, ceil(CGFloat(CTLineGetTypographicBounds(line(text, in: width), nil, nil, nil))))
    }

    /// Draws `text` on one line, truncated to `frame`'s width, its line box
    /// (`lineHeight`, from the font's ascent and descent) centred at
    /// `frame`'s top.
    private static func drawLine(_ text: NSAttributedString, in frame: NSRect, lineHeight: CGFloat) {
        guard frame.width > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let line = line(text, in: frame.width)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let height = ceil(ascent + descent + leading)
        let baseline = frame.minY + ((lineHeight - height) / 2).rounded() + ascent
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: frame.minX, y: baseline)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func draw(_ badge: Badge, in frame: NSRect, secondary: NSColor) {
        switch badge {
        case .silenced:
            guard let image = Self.silencedImage else { return }
            Self.drawSymbol(image, color: secondary, in: frame)
        case .new:
            drawPill(text: "New", textColor: .controlAccentColor,
                     fill: NSColor.controlAccentColor.withAlphaComponent(0.15), icon: nil, in: frame)
        case .needsYou(let text):
            drawPill(text: text, textColor: .white, fill: .systemOrange, icon: Self.needsYouImage, in: frame)
        case .unread(let text):
            drawPill(text: text, textColor: .white, fill: .controlAccentColor, icon: nil, in: frame)
        }
    }

    private func drawPill(text: String, textColor: NSColor, fill: NSColor, icon: NSImage?, in frame: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
        let string = Self.badgeString(text, color: textColor)
        let textSize = string.size()
        var contentWidth = ceil(textSize.width)
        if let icon { contentWidth += ceil(icon.size.width) + Self.badgeIconSpacing }
        var x = frame.minX + ((frame.width - contentWidth) / 2).rounded()
        if let icon {
            let iconFrame = NSRect(x: x, y: frame.minY + ((frame.height - icon.size.height) / 2).rounded(),
                                   width: icon.size.width, height: icon.size.height)
            Self.drawSymbol(icon, color: textColor, in: iconFrame)
            x += ceil(icon.size.width) + Self.badgeIconSpacing
        }
        let y = frame.minY + ((frame.height - ceil(textSize.height)) / 2).rounded()
        string.draw(at: NSPoint(x: x, y: y))
    }

    /// Draws a template symbol in `color`, centred in `frame`.
    private static func drawSymbol(_ image: NSImage, color: NSColor, in frame: NSRect) {
        let size = image.size
        let rect = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width,
                          height: size.height)
        // Resolved now, in the view's appearance; tinted opaque and drawn at
        // the colour's alpha (a translucent fill atop the black template
        // glyph would leave it black).
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let opaque = resolved.withAlphaComponent(1)
        let tinted = NSImage(size: size, flipped: false) { bounds in
            image.draw(in: bounds)
            opaque.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: resolved.alphaComponent,
                    respectFlipped: true, hints: nil)
    }

    // MARK: Accessibility

    /// One label for the row, in the order VoiceOver reads a chat row:
    /// "title, snippet, 2 unread, 1 needs you, 5 minutes ago".
    static func accessibilityLabel(for row: MacSidebarChat, now: Date) -> String {
        let summary = row.summary
        var parts = [SessionTag.accessibilityTitle(chatTitle: summary.title, boxName: summary.boxName,
                                                   sessionShort: summary.sessionShort,
                                                   roomBoxNames: summary.roomBoxNames)]
        if !summary.snippet.isEmpty { parts.append(summary.snippet) }
        if summary.unreadCount > 0 { parts.append("\(summary.unreadCount) unread") }
        if summary.needsUserCount > 0 { parts.append("\(summary.needsUserCount) needs you") }
        if row.isSilenced { parts.append("notifications off") }
        if row.isNew { parts.append("new session") }
        if let lastActivity = summary.lastActivity { parts.append(spokenTime(lastActivity, now: now)) }
        return parts.joined(separator: ", ")
    }

    /// `RelativeMinuteTimeView.format` in words: "now", "5 minutes ago",
    /// "1 hour ago", "3 days ago", else the short date it shows.
    static func spokenTime(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        func ago(_ count: Int, _ unit: String) -> String { "\(count) \(unit)\(count == 1 ? "" : "s") ago" }
        if interval < 60 { return "now" }
        if interval < 3600 { return ago(Int(interval / 60), "minute") }
        if interval < 86400 { return ago(Int(interval / 3600), "hour") }
        if interval < 86400 * 7 { return ago(Int(interval / 86400), "day") }
        return RelativeMinuteTimeView.format(date, now: now)
    }
}
