import AppKit
import MatronDesignSystem
import MatronModels

/// The AppKit For you list's item row: the native twin of `ItemRow` as
/// `DecisionsListView` lays it out on the Mac, drawn by hand so its height
/// is known up front without laying out a view, and a content change costs
/// a redraw of one row rather than a SwiftUI graph per row.
///
/// Same parts, fonts, colours and spacing as `ItemRow` in its Mac inbox
/// row (`macInboxRow`):
///
/// - the kind glyph (13 pt, in the kind's tint) in a 20 pt column;
/// - the first line: `#412` (10 pt monospaced digits, secondary), centred
///   on the title, then the title (13 pt medium; regular and secondary for
///   a notice) on up to two lines;
/// - the body, on one line (11 pt, secondary), when there is one;
/// - the caption line (10 pt): "Consent", the origin, the mission chip,
///   the status ("Needs you", "To read", "Answered · 2h ago", "With the
///   agent") and the comment count;
/// - trailing: the photo placeholder for an item with an image, and the
///   "Seen" button for a notice that offers it (a real button);
/// - a hairline under every row, edge to edge.
///
/// `MacItemRowCellSnapshotTests` holds it to `DecisionsListView`'s
/// geometry, light and dark, on the same fixtures.
final class MacItemRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("decisions.item")

    /// Which list the row is in. The two lists hold `ItemRow` in
    /// different rows: For you's inbox row, and the items pane's inset
    /// `List`.
    enum Style: Equatable {
        /// `DecisionsListView`'s `macInboxRow`: `ItemRow` with 12 pt each
        /// side, plus the Mac `List`'s own 8 pt, and 6 pt above and below;
        /// a hairline under the row, edge to edge.
        case inbox
        /// `ItemsListView`'s inset `List`: 16 pt each side and 4 pt above
        /// and below; the separator starts under the text.
        case pane

        var leading: CGFloat { self == .inbox ? 20 : 16 }
        var trailing: CGFloat { self == .inbox ? 20 : 16 }
        /// Above and below the content.
        var vertical: CGFloat { self == .inbox ? 6 : 4 }
    }

    /// How a row shows its item, besides the item itself.
    struct Presentation: Equatable {
        var style: Style = .inbox
        /// The origin chat's title on the caption line; `nil` shows none.
        var origin: String?
        /// The Done tab: a closed caption ("Answered · 2h ago"), no Seen.
        var isClosedTab = false
        /// Whether a notice that offers it gets the Seen button.
        var offersSeen = true

        func showsSeen(_ item: TrackerItem) -> Bool { offersSeen && !isClosedTab && item.offersSeen }
    }

    enum Metrics {
        static let glyphWidth: CGFloat = 20
        static let glyphTop: CGFloat = 2
        static let glyphLineHeight: CGFloat = 16
        /// Between the glyph, the text and the image.
        static let columnSpacing: CGFloat = 10
        /// Between `#412` and the title.
        static let numSpacing: CGFloat = 6
        /// Between the lines.
        static let lineSpacing: CGFloat = 2
        static let titleLineHeight: CGFloat = 16
        static let titleMaxLines = 2
        static let bodyLineHeight: CGFloat = 14
        /// The caption line: plain text, a line with an icon label (the
        /// mission chip, the comment count), and one with "Consent".
        static let captionLineHeight: CGFloat = 13
        static let captionIconLineHeight: CGFloat = 14
        static let captionConsentLineHeight: CGFloat = 15
        static let captionSpacing: CGFloat = 8
        /// Between a label's icon and its text.
        static let labelIconSpacing: CGFloat = 4
        static let imageSide: CGFloat = 40
        /// Between the row and the Seen button.
        static let seenSpacing: CGFloat = 8
    }

    enum Fonts {
        static let glyph = NSFont.systemFont(ofSize: 13)
        static let num = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        static let title = NSFont.systemFont(ofSize: 13, weight: .medium)
        static let noticeTitle = NSFont.systemFont(ofSize: 13)
        static let body = NSFont.systemFont(ofSize: 11)
        static let caption = NSFont.systemFont(ofSize: 10)
        static let captionStrong = NSFont.systemFont(ofSize: 10, weight: .semibold)
        static let captionDigits = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    }

    /// The row shown, its "Answered · 2h ago" caption as of `now`, and
    /// whether it carries the Seen button.
    private(set) var item: TrackerItem?
    private(set) var presentation = Presentation()
    private(set) var closedCaption: String?
    private(set) var showsSeen = false
    /// The Seen button's action; set by the rows on every configure.
    var onSeen: (() -> Void)?

    let seenButton: NSButton = {
        let button = NSButton(title: TrackerItem.seenAction, target: nil, action: nil)
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.setAccessibilityIdentifier("decisions.seen")
        button.isHidden = true
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        seenButton.target = self
        seenButton.action = #selector(seenTapped(_:))
        addSubview(seenButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Shows `item`, and says whether anything changed. Idempotent: an
    /// unchanged row and caption draw nothing.
    @discardableResult
    func configure(_ item: TrackerItem, origin: String, isClosedTab: Bool, now: Date) -> Bool {
        configure(item, presentation: Presentation(origin: origin, isClosedTab: isClosedTab), now: now)
    }

    @discardableResult
    func configure(_ item: TrackerItem, presentation: Presentation, now: Date) -> Bool {
        let caption = presentation.isClosedTab ? ItemGlyph.closedCaption(item, at: item.closedSortDate, now: now) : nil
        let seen = presentation.showsSeen(item)
        guard item != self.item || presentation != self.presentation || caption != closedCaption
                || seen != showsSeen else {
            return false
        }
        self.item = item
        self.presentation = presentation
        closedCaption = caption
        showsSeen = seen
        seenButton.isHidden = !seen
        seenButton.setAccessibilityLabel("\(TrackerItem.seenAction): \(item.title)")
        needsLayout = true
        needsDisplay = true
        return true
    }

    @objc private func seenTapped(_ sender: Any?) { onSeen?() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let item else { return }
        if let frame = Self.layout(for: item, origin: presentation.origin, closedCaption: closedCaption,
                                   showsSeen: showsSeen, style: presentation.style, width: bounds.width).seen {
            seenButton.frame = frame
        }
    }

    // MARK: Layout

    enum CaptionPart: Equatable {
        case consent
        case origin(String)
        case mission(String)
        case status(String, Status)
        case comments(String)
    }

    enum Status: Equatable {
        /// "Needs you", in orange.
        case needsYou
        /// "To read", a notice waiting on the user.
        case notice
        /// A closed or with-the-agent caption.
        case quiet
    }

    /// Where each part goes: the drawing, the heights and the tests read
    /// the same frames.
    struct Layout: Equatable {
        var height: CGFloat
        var glyph: NSRect
        var num: NSRect
        var titleLines: Int
        var title: NSRect
        var body: NSRect?
        var caption: [CaptionFrame]
        var image: NSRect?
        var seen: NSRect?
    }

    struct CaptionFrame: Equatable {
        var part: CaptionPart
        var frame: NSRect
    }

    /// The caption line's parts, in `ItemRow`'s order.
    static func captionParts(for item: TrackerItem, origin: String?, closedCaption: String?) -> [CaptionPart] {
        var parts: [CaptionPart] = []
        if item.isConsentAsk { parts.append(.consent) }
        if let origin { parts.append(.origin(origin)) }
        if let chip = ItemRow.missionChipText(for: item) { parts.append(.mission(chip)) }
        if item.needsUser && item.kind == .notice {
            parts.append(.status(ItemGlyph.label(.notice), .notice))
        } else if item.needsUser {
            parts.append(.status("Needs you", .needsYou))
        } else if item.state == .closed {
            parts.append(.status(closedCaption ?? item.resolution.map(ItemGlyph.label) ?? "Closed", .quiet))
        } else if let closedCaption {
            parts.append(.status(closedCaption, .quiet))
        } else if item.awaiting == .agent {
            parts.append(.status("With the agent", .quiet))
        }
        if item.commentCount > 0 { parts.append(.comments("\(item.commentCount)")) }
        return parts
    }

    /// The caption line's height: SwiftUI's line grows a point for an icon
    /// label, and another for "Consent" (semibold).
    static func captionLineHeight(_ parts: [CaptionPart]) -> CGFloat {
        if parts.contains(.consent) { return Metrics.captionConsentLineHeight }
        for part in parts {
            switch part {
            case .mission, .comments: return Metrics.captionIconLineHeight
            default: continue
            }
        }
        return Metrics.captionLineHeight
    }

    static func bodyText(for item: TrackerItem) -> String? {
        guard !item.body.isEmpty else { return nil }
        return inlineAttachmentPlainText(item.body).replacingOccurrences(of: "\n", with: " ")
    }

    static func layout(for item: TrackerItem, origin: String?, closedCaption: String?, showsSeen: Bool,
                       style: Style = .inbox, width: CGFloat) -> Layout {
        let left = style.leading
        let top = style.vertical
        let seenSize = showsSeen ? seenButtonSize : .zero
        // `ItemRow`'s width: the row, less the Seen button beside it.
        let rowRight = width - style.trailing - (showsSeen ? seenSize.width + Metrics.seenSpacing : 0)
        // `ItemRow` ends with `Spacer(minLength: 0)` (and the image), so the
        // text column always stops one spacing short.
        let imageFrame: NSRect? = item.hasImage
            ? NSRect(x: rowRight - Metrics.imageSide, y: top, width: Metrics.imageSide, height: Metrics.imageSide) : nil
        let textLeft = left + Metrics.glyphWidth + Metrics.columnSpacing
        let textRight = (imageFrame.map { $0.minX - Metrics.columnSpacing } ?? rowRight) - Metrics.columnSpacing
        let textWidth = max(0, textRight - textLeft)

        // The first line: `#412`, then the title on up to two lines.
        let num = numString(item.num, color: .secondaryLabelColor)
        let numWidth = MacChatListCell.fittedWidth(num, in: .greatestFiniteMagnitude)
        let titleLeft = textLeft + numWidth + Metrics.numSpacing
        let titleWidth = max(0, textRight - titleLeft)
        let lines = titleLines(titleString(item, color: .labelColor), width: titleWidth).count
        let titleHeight = CGFloat(max(1, lines)) * Metrics.titleLineHeight
        let titleFrame = NSRect(x: titleLeft, y: top, width: titleWidth, height: titleHeight)
        let numFrame = NSRect(x: textLeft, y: top + ((titleHeight - Metrics.titleLineHeight) / 2).rounded(),
                              width: numWidth, height: Metrics.titleLineHeight)

        var y = top + titleHeight
        var bodyFrame: NSRect?
        if bodyText(for: item) != nil {
            y += Metrics.lineSpacing
            bodyFrame = NSRect(x: textLeft, y: y, width: textWidth, height: Metrics.bodyLineHeight)
            y += Metrics.bodyLineHeight
        }

        // The caption line, each part centred on it; the origin gives way.
        let parts = captionParts(for: item, origin: origin, closedCaption: closedCaption)
        // With nothing on it, SwiftUI's caption line has no height (its
        // spacing above stays).
        let lineHeight = parts.isEmpty ? 0 : captionLineHeight(parts)
        y += Metrics.lineSpacing
        let widths: [CGFloat] = parts.map { Self.width(of: $0) }
        var fixed: CGFloat = Metrics.captionSpacing * CGFloat(max(0, parts.count - 1))
        for (part, partWidth) in zip(parts, widths) {
            if case .origin = part { continue }
            fixed += partWidth
        }
        var x = textLeft
        var caption: [CaptionFrame] = []
        for (part, partWidth) in zip(parts, widths) {
            var w = partWidth
            if case .origin = part { w = min(partWidth, max(0, textWidth - fixed)) }
            caption.append(CaptionFrame(part: part, frame: NSRect(x: x, y: y, width: w, height: lineHeight)))
            x += w + Metrics.captionSpacing
        }
        y += lineHeight

        let textBottom = y
        let contentBottom = max(textBottom, top + Metrics.glyphTop + Metrics.glyphLineHeight,
                                imageFrame?.maxY ?? 0)
        let height = contentBottom + style.vertical
        let glyph = NSRect(x: left, y: top + Metrics.glyphTop, width: Metrics.glyphWidth,
                           height: Metrics.glyphLineHeight)
        let seen: NSRect? = showsSeen
            ? NSRect(x: width - style.trailing - seenSize.width, y: ((height - seenSize.height) / 2).rounded(),
                     width: seenSize.width, height: seenSize.height) : nil
        return Layout(height: height, glyph: glyph, num: numFrame, titleLines: max(1, lines), title: titleFrame,
                      body: bodyFrame, caption: caption, image: imageFrame, seen: seen)
    }

    /// The row's height at `width`.
    static func height(for item: TrackerItem, origin: String, isClosedTab: Bool, width: CGFloat) -> CGFloat {
        height(for: item, presentation: Presentation(origin: origin, isClosedTab: isClosedTab), width: width)
    }

    static func height(for item: TrackerItem, presentation: Presentation, width: CGFloat) -> CGFloat {
        // The Done caption's text changes with the clock, never its height.
        layout(for: item, origin: presentation.origin, closedCaption: presentation.isClosedTab ? "" : nil,
               showsSeen: presentation.showsSeen(item), style: presentation.style, width: width).height
    }

    /// The Seen button's size: measured once from a real button.
    static let seenButtonSize: NSSize = {
        let button = NSButton(title: TrackerItem.seenAction, target: nil, action: nil)
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.sizeToFit()
        return button.frame.size
    }()

    // MARK: Text

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    static func numString(_ num: Int, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: "#\(num)", attributes: [.font: Fonts.num, .foregroundColor: color])
    }

    static func titleString(_ item: TrackerItem, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: item.title, attributes: [
            .font: item.kind == .notice ? Fonts.noticeTitle : Fonts.title, .foregroundColor: color,
        ])
    }

    static func bodyString(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Fonts.body, .foregroundColor: color,
                                                      .paragraphStyle: truncating])
    }

    static func captionString(_ text: String, font: NSFont = Fonts.caption, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color,
                                                      .paragraphStyle: truncating])
    }

    /// `text` wrapped to `width` on at most `maxLines` lines, the last one
    /// truncated with an ellipsis when the text runs on.
    static func titleLines(_ text: NSAttributedString, width: CGFloat,
                           maxLines: Int = Metrics.titleMaxLines) -> [CTLine] {
        guard width > 0, text.length > 0 else { return [] }
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var lines: [CTLine] = []
        var start = 0
        let string = text.string as NSString
        while start < text.length, lines.count < maxLines {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard count > 0 else { break }
            // SwiftUI's `Text` keeps a last line from holding one word
            // alone: when the rest is a single word that fits, the line
            // before it gives up its own last word.
            if start + count < text.length, lines.count == maxLines - 2 {
                count = Self.breakAvoidingOrphan(in: string, typesetter: typesetter, start: start, count: count,
                                                 width: width)
            }
            if lines.count == maxLines - 1, start + count < text.length {
                let rest = text.attributedSubstring(from: NSRange(location: start, length: text.length - start))
                lines.append(MacChatListCell.line(rest, in: width))
                break
            }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        return lines
    }

    /// The break after `count` characters from `start`, moved back to the
    /// line's last space when what follows is one word on a last line of
    /// its own. Unchanged when the rest is more than a word, would not fit
    /// on one line once it takes the moved word, or the line has no space.
    static func breakAvoidingOrphan(in string: NSString, typesetter: CTTypesetter, start: Int, count: Int,
                                    width: CGFloat) -> Int {
        let restRange = NSRange(location: start + count, length: string.length - start - count)
        let rest = string.substring(with: restRange).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, !rest.contains(" ") else { return count }
        let line = string.substring(with: NSRange(location: start, length: count))
            .trimmingCharacters(in: .whitespaces) as NSString
        let lastSpace = line.range(of: " ", options: .backwards)
        guard lastSpace.location != NSNotFound, lastSpace.location > 0 else { return count }
        let moved = lastSpace.location + 1
        let tail = CTTypesetterCreateLine(typesetter, CFRange(location: start + moved, length: string.length - start - moved))
        guard CGFloat(CTLineGetTypographicBounds(tail, nil, nil, nil)) <= width else { return count }
        return moved
    }

    private static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    }

    private static var glyphs: [ItemKind: NSImage] = [:]

    static func glyphImage(_ kind: ItemKind) -> NSImage? {
        if let cached = glyphs[kind] { return cached }
        let image = symbol(ItemGlyph.symbol(kind), pointSize: 13)
        glyphs[kind] = image
        return image
    }

    static let consentImage = symbol("hand.raised", pointSize: 10, weight: .semibold)
    static let missionImage = symbol(MissionGlyph.symbol(), pointSize: 10)
    static let commentsImage = symbol("bubble.left", pointSize: 10)
    static let photoImage = symbol("photo", pointSize: 13)

    static func glyphTint(_ kind: ItemKind) -> NSColor {
        switch kind {
        case .question: .systemOrange
        case .task: .controlAccentColor
        case .decision: .systemPurple
        case .notice: .secondaryLabelColor
        }
    }

    private static func icon(of part: CaptionPart) -> NSImage? {
        switch part {
        case .consent: consentImage
        case .mission: missionImage
        case .comments: commentsImage
        case .origin, .status: nil
        }
    }

    private static func text(of part: CaptionPart, color: NSColor) -> NSAttributedString {
        switch part {
        case .consent: captionString("Consent", font: Fonts.captionStrong, color: color)
        case .origin(let text): captionString(text, color: color)
        case .mission(let text): captionString(text, font: Fonts.captionDigits, color: color)
        case .status(let text, let status):
            captionString(text, font: status == .quiet ? Fonts.caption : Fonts.captionStrong, color: color)
        case .comments(let text): captionString(text, color: color)
        }
    }

    static func width(of part: CaptionPart) -> CGFloat {
        let textWidth = MacChatListCell.fittedWidth(text(of: part, color: .labelColor), in: .greatestFiniteMagnitude)
        guard let icon = icon(of: part) else { return textWidth }
        return ceil(icon.size.width) + Metrics.labelIconSpacing + textWidth
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let emphasized = backgroundStyle == .emphasized
        let selected = NSColor.alternateSelectedControlTextColor
        let primary: NSColor = emphasized ? selected : .labelColor
        let secondary: NSColor = emphasized ? selected.withAlphaComponent(0.75) : .secondaryLabelColor
        let tertiary: NSColor = emphasized ? selected.withAlphaComponent(0.6) : .tertiaryLabelColor
        let style = presentation.style
        let layout = Self.layout(for: item, origin: presentation.origin, closedCaption: closedCaption,
                                 showsSeen: showsSeen, style: style, width: bounds.width)

        if let glyph = Self.glyphImage(item.kind) {
            let tint = item.kind == .notice ? secondary : (emphasized ? selected : Self.glyphTint(item.kind))
            MacChatListCell.drawSymbol(glyph, color: tint, in: layout.glyph)
        }
        MacChatListCell.drawLine(Self.numString(item.num, color: secondary), in: layout.num,
                                 lineHeight: Metrics.titleLineHeight)
        let title = Self.titleString(item, color: item.kind == .notice ? secondary : primary)
        for (index, line) in Self.titleLines(title, width: layout.title.width).enumerated() {
            Self.draw(line, at: NSPoint(x: layout.title.minX,
                                        y: layout.title.minY + CGFloat(index) * Metrics.titleLineHeight),
                      lineHeight: Metrics.titleLineHeight)
        }
        if let frame = layout.body, let text = Self.bodyText(for: item) {
            MacChatListCell.drawLine(Self.bodyString(text, color: secondary), in: frame,
                                     lineHeight: Metrics.bodyLineHeight)
        }
        for part in layout.caption {
            let color: NSColor
            switch part.part {
            case .consent: color = secondary
            case .status(_, .needsYou): color = emphasized ? selected : .systemOrange
            case .status(_, .notice): color = secondary
            default: color = tertiary
            }
            drawCaption(part.part, in: part.frame, color: color)
        }
        if let frame = layout.image, let photo = Self.photoImage {
            MacChatListCell.drawSymbol(photo, color: tertiary, in: frame)
        }
        // The hairline under the row: edge to edge in the inbox, from the
        // text to the trailing inset in the pane.
        let scale = window?.backingScaleFactor ?? 2
        let lineLeft = style == .inbox ? 0 : layout.num.minX
        let lineRight = style == .inbox ? bounds.width : bounds.width - style.trailing
        NSColor.separatorColor.setFill()
        NSRect(x: lineLeft, y: bounds.height - 1 / scale, width: max(0, lineRight - lineLeft), height: 1 / scale).fill()
    }

    private func drawCaption(_ part: CaptionPart, in frame: NSRect, color: NSColor) {
        var textFrame = frame
        if let icon = Self.icon(of: part) {
            let side = ceil(icon.size.width)
            MacChatListCell.drawSymbol(icon, color: color,
                                       in: NSRect(x: frame.minX, y: frame.minY, width: side, height: frame.height))
            textFrame.origin.x += side + Metrics.labelIconSpacing
            textFrame.size.width = max(0, frame.width - side - Metrics.labelIconSpacing)
        }
        MacChatListCell.drawLine(Self.text(of: part, color: color), in: textFrame, lineHeight: frame.height)
    }

    /// Draws one laid-out line in `frame`, its line box at the top.
    static func draw(_ line: CTLine, in frame: NSRect) {
        draw(line, at: frame.origin, lineHeight: frame.height)
    }

    /// Draws one laid-out line with its line box at `origin`.
    private static func draw(_ line: CTLine, at origin: NSPoint, lineHeight: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let height = ceil(ascent + descent + leading)
        let baseline = origin.y + ((lineHeight - height) / 2).rounded() + ascent
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: origin.x, y: baseline)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: Accessibility

    static func accessibilityLabel(for item: TrackerItem, origin: String?, isClosedTab: Bool, now: Date) -> String {
        let caption = isClosedTab ? ItemGlyph.closedCaption(item, at: item.closedSortDate, now: now) : nil
        return ItemRow.accessibilityLabel(for: item, caption: caption) + (origin.map { ", \($0)" } ?? "")
    }
}

/// The Done tab's "Show more" under its window: secondary text, drawn
/// like the item rows, with a transparent button the size of the row over
/// it, so a click grows the window without selecting a row.
final class MacDecisionsShowMoreCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("decisions.showMore")
    static let rowHeight: CGFloat = 24
    static let title = "Show more"
    static let font = NSFont.systemFont(ofSize: 13)

    var onShowMore: (() -> Void)?

    let button: NSButton = {
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.isTransparent = true
        button.setAccessibilityLabel(MacDecisionsShowMoreCell.title)
        button.setAccessibilityIdentifier("decisions.showMoreDecided")
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        button.target = self
        button.action = #selector(tapped(_:))
        button.frame = bounds
        button.autoresizingMask = [.width, .height]
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = NSAttributedString(string: Self.title, attributes: [
            .font: Self.font, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let width = MacChatListCell.fittedWidth(text, in: bounds.width)
        let lineHeight: CGFloat = 16
        let frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - lineHeight) / 2).rounded(),
                           width: width, height: lineHeight)
        MacChatListCell.drawLine(text, in: frame, lineHeight: lineHeight)
    }

    @objc private func tapped(_ sender: Any?) { onShowMore?() }
}
