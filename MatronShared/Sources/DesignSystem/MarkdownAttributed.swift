#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import os

/// Markdown → `NSAttributedString` converter shared by the Mac timeline (AppKit) and the iOS UIKit timeline.
///
/// `MarkdownText` (MarkdownUI) renders each markdown block as a separate SwiftUI
/// `Text`, and `.textSelection(.enabled)` can't span sibling `Text`s — so a
/// mouse drag selects at most one paragraph. For whole/partial-message selection
/// on the Mac we render message bodies through a single selectable `NSTextView`
/// (`SelectableMessageText`), which needs one flat `NSAttributedString` for the
/// entire message.
///
/// This type parses the markdown source with Apple's
/// `AttributedString(markdown:options:)` (`.full` interpreted syntax, extended
/// attributes on), then walks the runs and maps each run's `presentationIntent`
/// (block level) and `inlinePresentationIntent` (inline level) onto visual
/// AppKit attributes. It deliberately mirrors `MarkdownText`'s look — same body
/// scale, same inline-code / code-block chrome, same link-handling policy — so
/// the two renderers are visually interchangeable.
///
/// Heights derived from these strings must be deterministic (see
/// `SelectableMessageText.sizeThatFits`), so the output is a pure function of the
/// source; converted strings are memoised in an `NSCache` keyed on the source,
/// mirroring `MarkdownText.contentCache`.
public enum MarkdownAttributed {

    // MARK: - Sizing constants

    /// The per-surface metrics of a render: body size, paragraph gap and
    /// leading. Everything else about the conversion (indents, heading
    /// ratios, code chrome, link policy) is shared, so a chat message and
    /// a tracker item read as the same markdown at two reading scales.
    /// `Hashable` because it is half of the memo key (see `rendered`).
    public struct Style: Hashable, Sendable {
        /// Body point size; headings and inline code scale off it.
        public let baseFontSize: CGFloat
        /// Space after a paragraph, in points — the visual gap MarkdownUI
        /// leaves between blocks.
        public let paragraphSpacing: CGFloat
        /// Extra leading between wrapped lines, on top of the font's own.
        public let lineSpacing: CGFloat

        #if os(macOS)
        /// The Mac chat timeline: the 13pt macOS system body at
        /// `MessageTextScale.scale` (≈14.3pt). This is the timeline's own,
        /// independent size — `Theme.matronMessage` renders at the plain
        /// system body size instead (its `.em` scale was a MarkdownUI
        /// no-op; see #823), so the two are not required to match.
        public static let chat = Style(baseFontSize: 13 * MessageTextScale.scale, paragraphSpacing: 8, lineSpacing: 0)
        #endif

        #if !os(macOS)
        /// The iOS UIKit chat timeline: `bodySize` is the Dynamic-Type-scaled body
        /// size (17pt at the default category — `Theme.matronMessage`'s system
        /// body); leading 4 matches the SwiftUI path's `MarkdownText(lineSpacing: 4)`,
        /// block gap 8 matches the Mac chat style.
        public static func phoneChat(bodySize: CGFloat) -> Style {
            Style(baseFontSize: bodySize, paragraphSpacing: 8, lineSpacing: 4)
        }
        #endif

        /// The tracker item thread: `ItemTypography`'s
        /// reading face — ≈16.25pt body, a real paragraph gap and the
        /// thread's leading — the same numbers `Theme.matronItem` gives
        /// MarkdownUI on iOS, so the two platforms' item bodies match.
        public static let item = Style(baseFontSize: ItemTypography.baseSize * ItemTypography.bodyScale,
                                       paragraphSpacing: ItemTypography.paragraphSpacing,
                                       lineSpacing: ItemTypography.lineSpacing)
    }

    #if os(macOS)
    /// The chat timeline's body size, kept as a name because the size
    /// discussion in `MarkdownText`/`ItemTypography` refers to it.
    static let baseFontSize: CGFloat = Style.chat.baseFontSize
    #endif

    /// Hanging indent for list items and block quotes, in points.
    private static let listIndent: CGFloat = 18
    private static let quoteIndent: CGFloat = 12
    private static let codeBlockIndent: CGFloat = 8

    /// Fenced code block box (Mac): the block's lines render as ONE box — a
    /// single background the text view draws behind its lines
    /// (`MessageCopyTextView.codeBlockBoxes`, `codeBlockBox(around:width:)`)
    /// — not a per-glyph `.backgroundColor`, which painted every line as its
    /// own strip. `codeBlockPadding` is the box's inset above the first and
    /// below the last line, reserved in the paragraph spacing so the box
    /// never crowds the neighbouring blocks. A wrapped code line hangs
    /// `codeBlockWrapIndent` further in than its first fragment, so a
    /// wrapped diagram row reads as one line continued, not two lines.
    static let codeBlockPadding: CGFloat = 6
    static let codeBlockCornerRadius: CGFloat = 6
    private static let codeBlockWrapIndent: CGFloat = 16

    /// The background box for one code block whose laid-out lines span
    /// `lines`: the full text width, `codeBlockPadding` above the first
    /// line and below the last (space `build` reserves in the block's
    /// paragraph spacing, so the box never overlaps a neighbouring block).
    static func codeBlockBox(around lines: CGRect, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: lines.minY - codeBlockPadding,
               width: width, height: lines.height + 2 * codeBlockPadding)
    }

    /// Extra space ABOVE a heading (on top of the previous block's
    /// `paragraphSpacing`), and the reduced space below it. Headings need
    /// clear air from the section they close and should sit close to the
    /// section they open ("not enough space between the
    /// bottom of one paragraph and the heading after it"). Suppressed for
    /// a message that STARTS with a heading — no dead band at the bubble
    /// top.
    private static let headerSpacingBefore: CGFloat = 10
    private static let headerSpacingAfter: CGFloat = 6

    /// Table chrome: hairline cell borders, compact padding, and the bottom
    /// margin the LAST row carries so the table clears the following block
    /// (a margin on the NSTextTable itself is ignored by layout — spike,
    /// 2026-08-11).
    private static let tableBorderWidth: CGFloat = 0.5
    private static let tableCellPadding: CGFloat = 4
    private static let tableBottomMargin: CGFloat = 8

    // MARK: - Public API

    /// Everything derived from one markdown source, memoised together: the
    /// attributed string, the (expensive, previously per-mount) table probe,
    /// and the per-width measured sizes. One cache entry per source replaces
    /// the old separate string-keyed size cache, whose key interpolated the
    /// ENTIRE source on every `sizeThatFits` call (O(content) per lookup —
    /// SwiftUI calls `sizeThatFits` several times per row per layout pass).
    public final class Rendered {
        public let attributed: NSAttributedString

        #if !os(macOS)
        /// The message split into prose / fenced code / table blocks for the iOS
        /// timeline (iOS has no `NSTextTable`; code gets its own scrollable view).
        public let segments: [MarkdownSegment]
        #endif

        #if os(macOS)
        /// True when `attributed` carries TextKit table blocks.
        ///
        /// `SelectableMessageText` uses this to opt its text view into TextKit
        /// 1 BEFORE the first layout. AppKit falls back to TextKit 1 on its
        /// own when it meets table blocks, but only once the view is in a
        /// window and only mid-layout: the view then re-sizes to the (correct,
        /// smaller) TextKit 1 height keeping its TOP edge fixed, which moves
        /// its origin out from under the frame SwiftUI placed it at — the
        /// message draws above its bubble and the first rows are clipped.
        ///
        /// Computed once at build time: the probe walks every paragraph-style
        /// run, and it used to run on every mount and every `updateNSView`.
        public let containsTable: Bool
        #endif

        /// Vertical text-container inset (top AND bottom) for a message that
        /// starts or ends with a fenced code block: the room the block's box
        /// needs above its first / below its last line. Inside a message
        /// that room is paragraph spacing, but TextKit (1 and 2) drops a
        /// document's leading `paragraphSpacingBefore` and never counts its
        /// trailing `paragraphSpacing` in the height, so at a message edge
        /// the box would be clipped by the view. Symmetric because
        /// `NSTextView`'s inset is — and its self-sizing (the view is
        /// vertically resizable) adds exactly `2 × inset`, which
        /// `size(width:)` mirrors. 0 for every other message.
        public let codeEdgeInset: CGFloat

        private var sizes: [CGFloat: CGSize] = [:]
        private let lock = NSLock()

        init(attributed: NSAttributedString) {
            self.attributed = attributed
            #if os(macOS)
            var found = false
            attributed.enumerateAttribute(
                .paragraphStyle, in: NSRange(location: 0, length: attributed.length)
            ) { value, _, stop in
                if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty {
                    found = true
                    stop.pointee = true
                }
            }
            self.containsTable = found
            #endif
            #if !os(macOS)
            self.segments = MarkdownSegmenter.segments(of: attributed)
            #endif

            let codeRanges = MarkdownAttributed.codeBlockRanges(in: attributed)
            self.codeBlockRanges = codeRanges
            let startsWithCode = codeRanges.first?.location == 0
            let endsWithCode = codeRanges.last.map { NSMaxRange($0) == attributed.length } ?? false
            self.codeEdgeInset = (startsWithCode || endsWithCode) ? MarkdownAttributed.codeBlockPadding : 0
        }

        /// Exact laid-out size of the string wrapped to `proposedWidth`.
        ///
        /// Width is the CONTENT's natural width (longest line fragment,
        /// rounded up), never the proposal — that's what lets a short
        /// message's bubble hug its text instead of spanning the pane. Height
        /// is re-measured at that hugged width so the reported (width, height)
        /// pair is exactly what the live text view will render.
        ///
        /// Measured against a standalone TextKit stack rather than a live
        /// `NSTextView`, so the result is a pure function of (source, width) —
        /// no dependence on a view's frame, `widthTracksTextView`, or layout
        /// timing. This is the size `SelectableMessageText` reports to SwiftUI;
        /// keeping it deterministic is what protects the timeline from height
        /// churn (bugbot, PR #37: heights must never be keyed on the RENDERED
        /// text — `**hi**` and `hi` render the same characters — which is why
        /// the memo lives on the per-SOURCE object).
        ///
        /// Memoised: SwiftUI calls `sizeThatFits` for every visible row on
        /// every layout pass, and the timeline is deliberately non-lazy
        /// (blank-chat cure), so an uncached TextKit layout here ran ~120 full
        /// measurements per scroll tick — the 2026-07 Mac scroll lag.
        public func size(width proposedWidth: CGFloat) -> CGSize {
            guard proposedWidth > 0, proposedWidth.isFinite else { return .zero }
            lock.lock()
            if let hit = sizes[proposedWidth] { lock.unlock(); return hit }
            lock.unlock()
            let first = MarkdownAttributed.layoutSize(for: attributed, width: proposedWidth, codeRanges: codeBlockRanges)
            var result = first
            // Hug: if the content is narrower than the proposal, re-wrap at the
            // hugged width so the height matches what the view renders at that
            // width (the ceil can shift a wrap boundary; measuring twice
            // removes the guess).
            if first.width < proposedWidth.rounded(.down) {
                let rewrapped = MarkdownAttributed.layoutSize(for: attributed, width: first.width, codeRanges: codeBlockRanges)
                result = CGSize(width: first.width, height: rewrapped.height)
            }
            result.height += 2 * codeEdgeInset
            lock.lock()
            sizes[proposedWidth] = result
            lock.unlock()
            return result
        }

        /// One fenced code block's laid-out geometry within the rendered
        /// message, for overlaying copy chrome (`SelectableMessageText`'s
        /// per-block copy button) on the text view.
        public struct CodeBlockFrame: Equatable {
            /// The block's bounding rect at the given width, in the text
            /// view's coordinate space (top-left origin, offset by
            /// `codeEdgeInset` — the geometry `SelectableMessageText`
            /// renders with).
            public let rect: CGRect
            /// The block's bare code, trailing newlines trimmed — what the
            /// copy button puts on the pasteboard.
            public let code: String
        }

        /// Code-block frames at `width` — the ACTUAL rendered width
        /// (`SelectableMessageText` hugs content, so callers pass the
        /// laid-out view width, not the proposal). Measured on the same
        /// standalone TextKit stack as `size(width:)` so rects match the
        /// live view; memoised per width alongside the sizes because SwiftUI
        /// re-evaluates overlays per layout pass and the timeline is
        /// non-lazy. Messages without code blocks never pay for a layout
        /// pass here. `textKit1` names the engine the live view runs when
        /// the caller forces one (`SelectableMessageText.defersTextView`);
        /// `nil` is the view's own choice, TextKit 1 only for tables.
        public func codeBlockFrames(width: CGFloat, textKit1: Bool? = nil) -> [CodeBlockFrame] {
            guard width > 0, width.isFinite, !codeBlockRanges.isEmpty else { return [] }
            #if os(macOS)
            let useTextKit1 = textKit1 ?? containsTable
            #else
            let useTextKit1 = true
            #endif
            let key = CodeFramesKey(width: width, textKit1: useTextKit1)
            lock.lock()
            if let hit = codeFrames[key] { lock.unlock(); return hit }
            lock.unlock()

            // Measured on the engine the live view runs — TextKit 1 for
            // tabled messages (`useTextKit1IfTabled`), TextKit 2 otherwise —
            // because the two place `lineSpacing` differently and a
            // TK1-measured button sat ~4pt off a TK2 view's box.
            let text = attributed.string as NSString
            let codeRanges = codeBlockRanges
            let inset = codeEdgeInset
            func measure(_ lineUnion: (NSRange) -> CGRect?) -> [CodeBlockFrame] {
                codeRanges.compactMap { range in
                    // The copied code drops the block's trailing newlines;
                    // the measured range keeps them — they terminate the
                    // block's lines, and a blank line before the closing
                    // fence is code.
                    var code = text.substring(with: range)
                    while code.hasSuffix("\n") { code.removeLast() }
                    guard !code.isEmpty, let union = lineUnion(range) else { return nil }
                    return CodeBlockFrame(rect: union.offsetBy(dx: 0, dy: inset), code: code)
                }
            }
            // Each stack is measured inside its own scope: a layout manager
            // holds its storage weakly, so the storage must still be alive.
            let frames: [CodeBlockFrame]
            if useTextKit1 {
                let textStorage = NSTextStorage(attributedString: attributed)
                let textContainer = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
                textContainer.lineFragmentPadding = 0
                let layoutManager = NSLayoutManager()
                layoutManager.addTextContainer(textContainer)
                textStorage.addLayoutManager(layoutManager)
                layoutManager.ensureLayout(for: textContainer)
                frames = measure { MarkdownAttributed.lineUnion(of: $0, in: layoutManager) }
                withExtendedLifetime(textStorage) {}
            } else {
                let content = NSTextContentStorage()
                let layoutManager = NSTextLayoutManager()
                content.addTextLayoutManager(layoutManager)
                let textContainer = NSTextContainer(size: CGSize(width: width, height: 0))
                textContainer.lineFragmentPadding = 0
                layoutManager.textContainer = textContainer
                content.attributedString = attributed
                frames = measure { MarkdownAttributed.lineUnion(of: $0, in: layoutManager) }
                withExtendedLifetime(content) {}
            }
            lock.lock()
            codeFrames[key] = frames
            lock.unlock()
            return frames
        }

        /// Character range of each fenced code block, in document order —
        /// consecutive `semanticsKey` runs grouped by block identity.
        /// Computed once at build time, like `containsTable`, so reads need
        /// no locking. The text view takes them with the string
        /// (`MessageCopyTextView.apply`) so it never has to rescan storage.
        let codeBlockRanges: [NSRange]

        /// Whether the message has any fenced code block — views with none
        /// skip every code-box computation.
        public var hasCodeBlocks: Bool { !codeBlockRanges.isEmpty }

        private var codeFrames: [CodeFramesKey: [CodeBlockFrame]] = [:]
        private struct CodeFramesKey: Hashable { let width: CGFloat; let textKit1: Bool }
    }

    /// Everything derived from markdown `source`, memoised per source and style
    /// (countLimit 400). `cache: false` still reads the memo but never stores —
    /// a streaming row's every intermediate text would otherwise evict the
    /// immutable history the memo exists for (same rule as `MarkdownText(cacheParsed:)`).
    public static func rendered(for source: String, style: Style, cache: Bool) -> Rendered {
        let key = source as NSString
        let memo = renderedCache(for: style)
        if let cached = memo.object(forKey: key) { return cached }
        let built = Rendered(attributed: build(from: source, style: style))
        if cache { memo.setObject(built, forKey: key) }
        return built
    }

    #if os(macOS)
    /// Mac entry point (unchanged contract): memoised, chat style by default.
    static func rendered(for source: String, style: Style = .chat) -> Rendered {
        rendered(for: source, style: style, cache: true)
    }

    /// Thin wrapper over `rendered(for:style:)` for callers that only need
    /// the string (copy-time reconstruction, tests).
    static func attributedString(for source: String, style: Style = .chat) -> NSAttributedString {
        rendered(for: source, style: style).attributed
    }
    #endif

    /// One memo per style, each keyed on the source alone: a body rendered
    /// for the chat and for an item are two entries (same characters,
    /// different fonts and heights), and a lookup still costs one hash of
    /// the source — no composite key to build. Styles are a closed, tiny
    /// set, so the dictionary never grows past a handful.
    private static func renderedCache(for style: Style) -> NSCache<NSString, Rendered> {
        cachesLock.lock()
        defer { cachesLock.unlock() }
        if let cache = renderedCaches[style] { return cache }
        let cache = NSCache<NSString, Rendered>()
        cache.countLimit = 400
        renderedCaches[style] = cache
        return cache
    }

    /// Custom attribute carrying `MarkdownRunSemantics` for copy-time
    /// markdown reconstruction (`MarkdownReconstruction`). Inert for layout —
    /// it must never influence rendering or measured size.
    static let semanticsKey = NSAttributedString.Key("matron.markdown.semantics")

    /// Bounded, thread-safe memos — mirror `MarkdownText.contentCache`
    /// (countLimit 400 each, evict under memory pressure). Guarded by
    /// `cachesLock` only for the dictionary itself; `NSCache` is its own
    /// lock.
    nonisolated(unsafe) private static var renderedCaches: [Style: NSCache<NSString, Rendered>] = [:]
    private static let cachesLock = NSLock()

    private static let log = Logger(subsystem: "chat.matron", category: "MarkdownAttributed")

    // MARK: - Size measurement

    /// One uncached TextKit layout pass: natural width (≤ `width`) and height.
    ///
    /// A code line's box needs `codeBlockPadding` of room past its last
    /// glyph, so when a code line is the widest content the natural width
    /// reserves it — otherwise the hugged view (and the box, which spans the
    /// view) ended flush against the glyphs.
    fileprivate static func layoutSize(for attributed: NSAttributedString, width: CGFloat,
                                       codeRanges: [NSRange]) -> CGSize {
        let textStorage = NSTextStorage(attributedString: attributed)
        let textContainer = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        // Match the live text view's geometry (see SelectableMessageText) so the
        // measured size equals the rendered size.
        textContainer.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        var naturalWidth = used.maxX
        for range in codeRanges {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, lineUsed, _, _, _ in
                naturalWidth = max(naturalWidth, lineUsed.maxX + codeBlockPadding)
            }
        }
        // `maxX`, not `width`: the used rect starts at the leftmost glyph,
        // so for content that is indented throughout (a message that is
        // only a code block or a quote) `width` under-reported the natural
        // width by the indent, and re-wrapping at that hugged width broke
        // every line.
        return CGSize(width: min(ceil(naturalWidth), width), height: ceil(used.height))
    }

    // MARK: - Conversion

    private static func build(from source: String, style renderStyle: Style) -> NSAttributedString {
        // Chat bodies are prose — see MarkdownSource for the one shape the
        // parser would otherwise swallow whole.
        let source = MarkdownSource.prepared(source)
        let attributed: AttributedString
        do {
            attributed = try AttributedString(
                markdown: source,
                options: .init(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            // Parsing should only fail on pathological input; fall back to the
            // raw source rendered as a single plain paragraph so the message is
            // never lost.
            log.debug("Markdown parse failed, rendering plain: \(error.localizedDescription, privacy: .public)")
            return NSAttributedString(
                string: source,
                attributes: [
                    .font: font(size: renderStyle.baseFontSize),
                    .foregroundColor: MarkdownPalette.label,
                    .paragraphStyle: paragraphStyle(for: .paragraph, style: renderStyle),
                ]
            )
        }

        let output = NSMutableAttributedString()
        var previousIntent: PresentationIntent?
        // Tracks whether the current run still belongs to the FIRST block —
        // flips at the first block boundary, never back. Headers suppress
        // their `paragraphSpacingBefore` on the first block; the flag is
        // per-BLOCK (not `output.length == 0`) so a first header whose text
        // spans several runs (e.g. inline code inside it) keeps one
        // consistent paragraph style across all of them.
        var isFirstBlock = true
        // Copy-time semantics state: each block boundary bumps the identity so
        // reconstruction can tell adjacent same-kind blocks (consecutive list
        // items) apart; the boundary "\n" carries the semantics of the block
        // it TERMINATES, so the identity changes exactly at the next block's
        // first character.
        var blockIdentity = 0
        var previousSemantics: MarkdownRunSemantics?
        // The block that carries each list item's marker, keyed by the item's
        // parser identity. Any OTHER block inside the same item — the
        // paragraph after a nested list, or a second paragraph — is a
        // continuation: indented under the item, no marker. Without this
        // every such block repeated the item's number ("1. 1. 1. 2. 2.").
        var listItemMarkerBlocks: [Int: PresentationIntent] = [:]

        // In-progress table state. One `NSTextTable` spans consecutive
        // `tableCell` blocks; cell coordinates that step BACKWARD mean a new
        // markdown table started back-to-back with the previous one.
        // `rowBlocks` remembers each row's cell blocks because the last row —
        // the one that carries the table's bottom margin — isn't knowable
        // until the table ends.
        #if os(macOS)
        var currentTable: NSTextTable?
        var currentRowBlocks: [Int: [NSTextTableBlock]] = [:]
        var previousCell: (row: Int, column: Int)?
        #endif
        var currentCellStyle: NSMutableParagraphStyle?

        // Closes the open table, if any. Mutating the cell blocks after their
        // runs were appended is safe: the paragraph styles hold references to
        // the block objects, and layout reads them long after `build` returns.
        func endTable() {
            #if os(macOS)
            if let lastRow = currentRowBlocks.keys.max() {
                for cellBlock in currentRowBlocks[lastRow] ?? [] {
                    cellBlock.setWidth(
                        tableBottomMargin, type: .absoluteValueType, for: .margin, edge: .maxY
                    )
                }
            }
            currentTable = nil
            currentRowBlocks = [:]
            previousCell = nil
            #endif
            currentCellStyle = nil
        }

        for run in attributed.runs {
            let intent = run.presentationIntent
            var block = BlockKind(intent)
            if case .listItem(let ordinal, let depth, _) = block, let intent,
               let item = BlockKind.innermostListItemIdentity(intent) {
                if let markerBlock = listItemMarkerBlocks[item] {
                    if markerBlock != intent {
                        block = .listItem(ordinal: ordinal, depth: depth, isContinuation: true)
                    }
                } else {
                    listItemMarkerBlocks[item] = intent
                }
            }
            let isNewBlock = intent != previousIntent

            // Block boundary: a new `presentationIntent` identity means a new
            // block. Separate it from the previous block with a newline (the
            // per-paragraph `paragraphSpacing` supplies the visual gap) and, for
            // list items, prepend the marker. Skipped when the previous block
            // already ends with its own newline — a fenced code block's run
            // text keeps the parser's trailing "\n", and doubling it rendered
            // an empty code-styled line between the block and the next
            // paragraph.
            if previousIntent != nil, isNewBlock {
                if !output.mutableString.hasSuffix("\n") {
                    var separatorAttrs: [NSAttributedString.Key: Any] = [:]
                    if let previousSemantics {
                        // Block + identity ONLY — reusing the previous run's
                        // full semantics would coalesce the separator into a
                        // trailing styled/linked run at copy time, embedding
                        // the newline inside the reconstructed delimiters
                        // (`**docs\n**`) or minting a bogus newline link.
                        separatorAttrs[Self.semanticsKey] = MarkdownRunSemantics(
                            block: previousSemantics.block,
                            blockIdentity: previousSemantics.blockIdentity,
                            inline: [],
                            link: nil
                        )
                    }
                    // After a cell this newline is that cell's paragraph
                    // TERMINATOR: TextKit only binds a paragraph to its table
                    // block when the terminating newline carries the cell's
                    // paragraph style too.
                    if case .tableCell = previousSemantics?.block ?? .paragraph, let currentCellStyle {
                        separatorAttrs[.paragraphStyle] = currentCellStyle
                        separatorAttrs[.font] = font(size: renderStyle.baseFontSize)
                    }
                    output.append(NSAttributedString(string: "\n", attributes: separatorAttrs))
                }
                blockIdentity += 1
                isFirstBlock = false
            }
            // Table bookkeeping is per BLOCK, not per run — a cell with inline
            // styling arrives as several runs that must share one cell block.
            if isNewBlock {
                if case .tableCell(let row, let column, let isHeader, let columnCount, let alignments) = block {
                    let style = NSMutableParagraphStyle()
                    #if os(macOS)
                    let table: NSTextTable
                    let continues = BlockKind.tableCellContinues((row, column), after: previousCell)
                    if let open = currentTable, continues {
                        table = open
                    } else {
                        endTable()
                        table = NSTextTable()
                        table.numberOfColumns = columnCount
                        table.layoutAlgorithm = .automaticLayoutAlgorithm
                        table.setContentWidth(100, type: .percentageValueType)
                        currentTable = table
                    }

                    let cellBlock = NSTextTableBlock(
                        table: table, startingRow: row, rowSpan: 1,
                        startingColumn: column, columnSpan: 1
                    )
                    cellBlock.setWidth(tableBorderWidth, type: .absoluteValueType, for: .border)
                    cellBlock.setBorderColor(.separatorColor)
                    cellBlock.setWidth(tableCellPadding, type: .absoluteValueType, for: .padding)
                    // A label-colour tint, not `controlBackgroundColor`: bot
                    // bubbles are pure white in light mode (`matronBubbleBot`),
                    // where `controlBackgroundColor` is ALSO white — the shade
                    // must be an overlay that reads on either appearance's
                    // bubble.
                    if isHeader { cellBlock.backgroundColor = .labelColor.withAlphaComponent(0.05) }
                    currentRowBlocks[row, default: []].append(cellBlock)
                    previousCell = (row, column)
                    style.textBlocks = [cellBlock]
                    #else
                    // iOS has no NSTextTable: cells stay plain aligned
                    // paragraphs here, and `MarkdownSegmenter` lifts them
                    // into a `MarkdownTable` segment for the hosted grid.
                    _ = (row, isHeader, columnCount)
                    #endif
                    style.paragraphSpacing = 0
                    // The render style's leading applies inside cells too —
                    // an item-style table read at chat leading beside 4pt
                    // prose (Bugbot, PR #232).
                    style.lineSpacing = renderStyle.lineSpacing
                    if column < alignments.count {
                        style.alignment = nsAlignment(alignments[column])
                    }
                    currentCellStyle = style
                } else {
                    endTable()
                }
            }
            if isNewBlock, let marker = block.marker {
                var markerAttrs = runAttributes(block: block, inline: [], link: nil, isFirstBlock: isFirstBlock, style: renderStyle)
                markerAttrs[Self.semanticsKey] = MarkdownRunSemantics(
                    block: block, blockIdentity: blockIdentity, inline: [], link: nil
                )
                output.append(NSAttributedString(string: marker, attributes: markerAttrs))
            }
            previousIntent = intent

            let semantics = MarkdownRunSemantics(
                block: block,
                blockIdentity: blockIdentity,
                inline: MarkdownInlineFlags(run.inlinePresentationIntent ?? []),
                link: run.link
            )
            previousSemantics = semantics

            let text = String(attributed[run.range].characters)
            guard !text.isEmpty else { continue }
            var attrs = runAttributes(
                block: block,
                inline: run.inlinePresentationIntent ?? [],
                link: run.link,
                isFirstBlock: isFirstBlock,
                style: renderStyle
            )
            // The cell's style carries its table block and column alignment;
            // every run of the cell shares it.
            if case .tableCell = block, let currentCellStyle {
                attrs[.paragraphStyle] = currentCellStyle
            }
            attrs[Self.semanticsKey] = semantics
            output.append(NSAttributedString(string: text, attributes: attrs))
        }

        // A message ENDING in a table still needs its last cell's terminator,
        // or that cell's paragraph never binds to its block and the row drops
        // out of layout. Mirrors the block-boundary separator's attributes.
        if case .tableCell = previousSemantics?.block ?? .paragraph,
           let currentCellStyle, !output.mutableString.hasSuffix("\n") {
            var terminatorAttrs: [NSAttributedString.Key: Any] = [
                .paragraphStyle: currentCellStyle,
                .font: font(size: renderStyle.baseFontSize),
            ]
            if let previousSemantics {
                terminatorAttrs[Self.semanticsKey] = MarkdownRunSemantics(
                    block: previousSemantics.block,
                    blockIdentity: previousSemantics.blockIdentity,
                    inline: [],
                    link: nil
                )
            }
            output.append(NSAttributedString(string: "\n", attributes: terminatorAttrs))
        }
        endTable()

        // Never end on a newline: a message whose LAST block is a fenced code
        // block otherwise carries the parser's trailing "\n" into layout as
        // an empty monospaced line + paragraph spacing — ~25pt of dead space
        // at the bottom of the bubble, and plan-style messages very often
        // end with a code block. Interior newlines are
        // untouched; only the string's tail is trimmed.
        while output.length > 0, output.mutableString.hasSuffix("\n") {
            #if os(macOS)
            let attrs = output.attributes(at: output.length - 1, effectiveRange: nil)
            if let style = attrs[.paragraphStyle] as? NSParagraphStyle, !style.textBlocks.isEmpty {
                break // table-cell terminator — structural, not dead space
            }
            #endif
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }

        applyCodeBlockParagraphStyles(to: output, style: renderStyle)
        return output
    }

    /// Union of the laid-out lines of `range` — a code block's full range,
    /// terminating newlines included — under TextKit 2: every line of every
    /// paragraph (layout fragment) the range covers, glyph box only (a
    /// line's `typographicBounds` exclude the paragraph spacing around it).
    /// Paragraph-wise rather than `enumerateTextSegments`, so a blank line
    /// before the closing fence (a paragraph that is only its "\n") counts
    /// and nothing spills into the paragraph after the block.
    static func lineUnion(of range: NSRange, in layoutManager: NSTextLayoutManager) -> CGRect? {
        guard let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let throughBlock = NSTextRange(location: content.documentRange.location, end: end) else { return nil }
        // From the DOCUMENT start: laying out only the block leaves the
        // fragments above it at estimated frames (their paragraph spacing
        // missing), which put the block 14pt high in the item style.
        layoutManager.ensureLayout(for: throughBlock)
        var union = CGRect.null
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            guard fragment.rangeInElement.location.compare(end) == .orderedAscending else { return false }
            let origin = fragment.layoutFragmentFrame.origin
            for line in fragment.textLineFragments {
                union = union.union(line.typographicBounds.offsetBy(dx: origin.x, dy: origin.y))
            }
            return true
        }
        return union.isNull ? nil : union
    }

    /// TextKit 1 twin of `lineUnion(of:in:)`: the used rects of the line
    /// fragments holding `range`'s glyphs (each "\n" glyph belongs to the
    /// line it ends, so a blank last line counts and the next paragraph
    /// does not).
    static func lineUnion(of range: NSRange, in layoutManager: NSLayoutManager) -> CGRect? {
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var union = CGRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            union = union.union(used)
        }
        return union.isNull ? nil : union
    }

    /// Character range of each fenced code block in `attributed`, in
    /// document order — consecutive `semanticsKey` runs grouped by block
    /// identity (a block can arrive as several runs).
    static func codeBlockRanges(in attributed: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        var openIdentity: Int?
        attributed.enumerateAttribute(
            semanticsKey, in: NSRange(location: 0, length: attributed.length)
        ) { value, subrange, _ in
            guard let semantics = value as? MarkdownRunSemantics,
                  semantics.block.isCodeBlock else {
                openIdentity = nil
                return
            }
            if semantics.blockIdentity == openIdentity, let last = ranges.indices.last {
                ranges[last] = NSUnionRange(ranges[last], subrange)
            } else {
                ranges.append(subrange)
                openIdentity = semantics.blockIdentity
            }
        }
        return ranges
    }

    /// Every "\n"-terminated line of a fenced block is its own TextKit
    /// paragraph, so a block-wide paragraph style put the render style's
    /// `paragraphSpacing` (and leading) under EVERY code line — a gap after
    /// each line of an ASCII diagram. Restyle per line once the block's
    /// extent is known (the trailing-newline trim has run, so the last
    /// paragraph really is the block's last line): no spacing or leading
    /// inside the block, `codeBlockPadding` before the first line, and the
    /// normal paragraph gap plus `codeBlockPadding` after the last.
    private static func applyCodeBlockParagraphStyles(to output: NSMutableAttributedString,
                                                      style renderStyle: Style) {
        let text = output.string as NSString
        for block in codeBlockRanges(in: output) {
            var lines: [NSRange] = []
            var location = block.location
            while location < NSMaxRange(block) {
                let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
                lines.append(NSIntersectionRange(paragraph, block))
                location = NSMaxRange(paragraph)
            }
            for (index, line) in lines.enumerated() {
                let style = codeLineParagraphStyle(isFirst: index == 0,
                                                   isLast: index == lines.count - 1,
                                                   style: renderStyle)
                output.addAttribute(.paragraphStyle, value: style, range: line)
            }
        }
    }

    /// Paragraph style for one line of a fenced code block — see
    /// `applyCodeBlockParagraphStyles`.
    private static func codeLineParagraphStyle(isFirst: Bool, isLast: Bool,
                                               style renderStyle: Style) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 0
        style.firstLineHeadIndent = codeBlockIndent
        style.headIndent = codeBlockIndent + codeBlockWrapIndent
        style.paragraphSpacingBefore = isFirst ? codeBlockPadding : 0
        style.paragraphSpacing = isLast ? renderStyle.paragraphSpacing + codeBlockPadding : 0
        return style
    }

    // MARK: - Attribute mapping

    /// Builds the AppKit attribute dictionary for a single run, combining its
    /// block context with its inline intents and any link.
    private static func runAttributes(
        block: BlockKind,
        inline: InlinePresentationIntent,
        link: URL?,
        isFirstBlock: Bool = false,
        style renderStyle: Style
    ) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .paragraphStyle: paragraphStyle(for: block, isFirstBlock: isFirstBlock, style: renderStyle),
        ]

        let isCode = block.isCodeBlock || inline.contains(.code)
        let isBold = block.isBold || inline.contains(.stronglyEmphasized)
        let isItalic = inline.contains(.emphasized)

        // Inline code steps down to 0.92em, mirroring `Theme.matron`'s
        // `FontSize(.em(0.92))`; code blocks render at a flat 12pt.
        let size: CGFloat
        if block.isCodeBlock {
            size = 12
        } else if inline.contains(.code) {
            size = block.fontSize(base: renderStyle.baseFontSize) * 0.92
        } else {
            size = block.fontSize(base: renderStyle.baseFontSize)
        }

        attrs[.font] = font(size: size, bold: isBold, italic: isItalic, monospaced: isCode)
        attrs[.foregroundColor] = block.foreground

        // Inline-code background. Uses `controlBackgroundColor` to match the
        // `.matronInlineCodeBg` alias at the bottom of `MarkdownText.swift`.
        // Fenced blocks carry none: a per-glyph background paints each line
        // as its own strip, so the block's one box is drawn behind the text
        // view instead (`MessageCopyTextView.codeBlockBoxes`).
        if inline.contains(.code), !block.isCodeBlock {
            attrs[.backgroundColor] = MarkdownPalette.codeBackground
        }

        if inline.contains(.strikethrough) {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        if let link {
            // Mirror `MarkdownText.handle(url:)`'s policy, via the same
            // `MatronItemLink.action(for:)` both renderers share: a URL that
            // gets swallowed (matrix-internal, and any `matron://` the
            // app has no opener for) never becomes a clickable link — it would
            // do nothing under the cursor — so it renders as plain accent
            // text with no `.link` attribute. Everything the app CAN act on
            // — item, conversation, mission and project links, and
            // ordinary web links — gets an
            // accent-coloured, underlined, clickable link.
            switch MatronItemLink.action(for: link) {
            case .swallow, .openConsent:
                attrs[.foregroundColor] = MarkdownPalette.accent
            case .openTrackerItem, .openConversation, .openPage, .system:
                attrs[.link] = link
                attrs[.foregroundColor] = MarkdownPalette.accent
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
        }

        return attrs
    }

    /// Paragraph style for a block: the render style's body spacing and
    /// leading plus block-specific indents. A fresh instance per run keeps
    /// the styles value-safe.
    private static func paragraphStyle(for block: BlockKind, isFirstBlock: Bool = false,
                                       style renderStyle: Style) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        let paragraphSpacing = renderStyle.paragraphSpacing
        style.lineSpacing = renderStyle.lineSpacing
        switch block {
        case .listItem(_, let depth, let isContinuation):
            // Hanging indent so wrapped lines align past the marker; each
            // nesting level steps one indent in. A continuation has no
            // marker, so its first line starts at the item's text column.
            let textIndent = listIndent * CGFloat(depth + 1)
            style.firstLineHeadIndent = isContinuation ? textIndent : listIndent * CGFloat(depth)
            style.headIndent = textIndent
            style.paragraphSpacing = 2
        case .blockQuote:
            style.headIndent = quoteIndent
            style.firstLineHeadIndent = quoteIndent
            style.paragraphSpacing = paragraphSpacing
        case .codeBlock:
            // Placeholder — `applyCodeBlockParagraphStyles` restyles every
            // code line once the block's first and last lines are known.
            return codeLineParagraphStyle(isFirst: false, isLast: false, style: renderStyle)
        case .header:
            // Air above (unless the message opens with the heading — no
            // dead band at the bubble top), tighter attachment below.
            style.paragraphSpacingBefore = isFirstBlock ? 0 : headerSpacingBefore
            style.paragraphSpacing = headerSpacingAfter
        case .paragraph:
            style.paragraphSpacing = paragraphSpacing
        case .tableCell:
            // Row height comes from the cell block's padding, not paragraph
            // spacing. The style that actually carries the cell's
            // `textBlocks` is built in `build(from:)`, where the table
            // instance is known.
            style.paragraphSpacing = 0
        }
        return style
    }

    /// `NSTextAlignment` for a parsed column alignment.
    private static func nsAlignment(_ alignment: TableAlignment) -> NSTextAlignment {
        switch alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    private static func font(
        size: CGFloat,
        bold: Bool = false,
        italic: Bool = false,
        monospaced: Bool = false
    ) -> MarkdownFont {
        MarkdownPlatform.font(size: size, bold: bold, italic: italic, monospaced: monospaced)
    }
}

// MARK: - Block classification

/// Column alignment of a parsed table, mirrored from
/// `PresentationIntent.TableColumn.Alignment` so `BlockKind` stays
/// self-contained (and Hashable) for copy-time semantics.
enum TableAlignment: Hashable {
    case left, center, right

    init(_ column: PresentationIntent.TableColumn) {
        switch column.alignment {
        case .center: self = .center
        case .right: self = .right
        default: self = .left
        }
    }
}

/// The subset of block-level markdown structure this converter renders,
/// distilled from a run's `PresentationIntent`. Carries the derived font size,
/// colour, weight, and (for lists) the marker to prepend. Internal (not
/// private) so `MarkdownRunSemantics`/`MarkdownReconstruction` can reuse the
/// same classification at copy time.
enum BlockKind: Hashable {
    case paragraph
    case header(level: Int)
    /// `language` is the fence's language hint — presentation ignores it, but
    /// copy-time reconstruction restores it onto the fence.
    case codeBlock(language: String?)
    case blockQuote
    /// `ordinal` is `nil` for unordered items (renders "• ") and the 1-based
    /// number for ordered items (renders "N. ") — both from the INNERMOST
    /// item and the list that directly contains it. `depth` is 0 for a
    /// top-level item, 1 for an item nested inside another, and so on.
    /// `isContinuation` marks a block of the item after the one carrying its
    /// marker (e.g. the paragraph following a nested list): no marker,
    /// indented to the item's text column.
    case listItem(ordinal: Int?, depth: Int, isContinuation: Bool)
    /// One table cell. `row` is 0-based with the header row as row 0 (Apple
    /// reports `tableHeaderRow` for the header and 1-based `tableRow` for
    /// body rows, so the numbering lines up naturally). `columnCount` and
    /// `alignments` ride on every cell so copy-time reconstruction can
    /// rebuild the delimiter row from any selected cell.
    case tableCell(row: Int, column: Int, isHeader: Bool,
                   columnCount: Int, alignments: [TableAlignment])

    init(_ intent: PresentationIntent?) {
        guard let components = intent?.components else {
            self = .paragraph
            return
        }
        // Inspect the block's intent components (a run can be nested, e.g. a
        // paragraph inside a list item inside a list). Order the checks from
        // most- to least-specific structural kind.
        // Components run innermost-first, so the first `listItem` is the
        // block's own item and the first list after it is the list that
        // directly contains it; outer items only add depth. (Taking the LAST
        // item/any ordered list gave a bullet nested in a numbered item its
        // parent's number.)
        var listOrdinal: Int?
        var isOrdered: Bool?
        var listItemCount = 0
        // A cell's table components arrive as siblings (cell + row + table),
        // so they accumulate across the loop instead of returning early.
        var cellColumn: Int?
        var cellRow: Int?
        var isHeaderRow = false
        var tableColumns: [PresentationIntent.TableColumn]?

        for component in components {
            switch component.kind {
            case .header(let level):
                self = .header(level: level)
                return
            case .codeBlock(let languageHint):
                self = .codeBlock(language: languageHint)
                return
            case .blockQuote:
                self = .blockQuote
                return
            case .listItem(let ordinal):
                if listItemCount == 0 { listOrdinal = ordinal }
                listItemCount += 1
            case .orderedList:
                if listItemCount == 1, isOrdered == nil { isOrdered = true }
            case .unorderedList:
                if listItemCount == 1, isOrdered == nil { isOrdered = false }
            case .tableCell(let columnIndex):
                cellColumn = columnIndex
            case .tableHeaderRow:
                cellRow = 0
                isHeaderRow = true
            case .tableRow(let rowIndex):
                cellRow = rowIndex
            case .table(let columns):
                tableColumns = columns
            default:
                break
            }
        }

        // Resolved before the list fallback: a cell that lost any of its three
        // components (defensive — the parser always emits all of them) stays a
        // paragraph rather than rendering half a table.
        if let cellColumn, let cellRow, let tableColumns {
            self = .tableCell(
                row: cellRow, column: cellColumn, isHeader: isHeaderRow,
                columnCount: tableColumns.count,
                alignments: tableColumns.map(TableAlignment.init)
            )
            return
        }

        if listItemCount > 0 {
            self = .listItem(ordinal: isOrdered == true ? listOrdinal : nil,
                             depth: listItemCount - 1, isContinuation: false)
        } else {
            self = .paragraph
        }
    }

    /// Font size for the block at a render style's body size `base`.
    /// Headers step up over the body size; keep it simple — h1 1.3×, h2
    /// 1.15×, h3 1.05×, h4–h6 fall back to body. (Walked down from
    /// 1.4/1.25/1.1 — headings read oversized inside chat bubbles.)
    func fontSize(base: CGFloat) -> CGFloat {
        switch self {
        case .header(let level):
            switch level {
            case 1: return base * 1.3
            case 2: return base * 1.15
            case 3: return base * 1.05
            default: return base
            }
        default:
            return base
        }
    }

    /// Whether a cell at `cell` continues the table whose previous cell was at
    /// `previous` (`nil` = no table open). Within one table cell coordinates
    /// only ever ADVANCE, and every table starts at row 0 / column 0, so a
    /// coordinate that steps backward is exactly the boundary between two
    /// back-to-back markdown tables.
    ///
    /// Shared so the renderer (`NSTextTable` grouping) and copy-time
    /// reconstruction (pipe-table grouping) split in the same places: when they
    /// disagreed, copying across adjacent tables emitted one merged table with
    /// a delimiter row wedged into its body.
    static func tableCellContinues(
        _ cell: (row: Int, column: Int), after previous: (row: Int, column: Int)?
    ) -> Bool {
        guard let previous else { return false }
        return cell.row > previous.row
            || (cell.row == previous.row && cell.column > previous.column)
    }

    /// Headers — and a table's header row — render bold.
    var isBold: Bool {
        if case .header = self { return true }
        if case .tableCell(_, _, let isHeader, _, _) = self { return isHeader }
        return false
    }

    var isCodeBlock: Bool {
        if case .codeBlock = self { return true }
        return false
    }

    /// Text colour: block quotes read as secondary; everything else is the
    /// primary label colour.
    var foreground: MarkdownColor {
        switch self {
        case .blockQuote: return MarkdownPalette.secondaryLabel
        default: return MarkdownPalette.label
        }
    }

    /// Parser identity of the innermost list item containing `intent`'s
    /// block, or `nil` outside lists.
    static func innermostListItemIdentity(_ intent: PresentationIntent) -> Int? {
        for component in intent.components {
            if case .listItem = component.kind { return component.identity }
        }
        return nil
    }

    /// Marker prepended at the start of a list item ("• " / "N. "). `nil` for
    /// every other block, and for a list item's continuation blocks.
    var marker: String? {
        guard case .listItem(let ordinal, _, let isContinuation) = self, !isContinuation else { return nil }
        if let ordinal { return "\(ordinal). " }
        return "\u{2022} "
    }
}

// MARK: - Copy-time semantics

/// Inline-style flags for one rendered run, mirrored from
/// `InlinePresentationIntent` at build time for copy-time reconstruction.
struct MarkdownInlineFlags: OptionSet, Hashable {
    let rawValue: Int
    static let bold = MarkdownInlineFlags(rawValue: 1 << 0)
    static let italic = MarkdownInlineFlags(rawValue: 1 << 1)
    static let code = MarkdownInlineFlags(rawValue: 1 << 2)
    static let strikethrough = MarkdownInlineFlags(rawValue: 1 << 3)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(_ intent: InlinePresentationIntent) {
        var flags: MarkdownInlineFlags = []
        if intent.contains(.stronglyEmphasized) { flags.insert(.bold) }
        if intent.contains(.emphasized) { flags.insert(.italic) }
        if intent.contains(.code) { flags.insert(.code) }
        if intent.contains(.strikethrough) { flags.insert(.strikethrough) }
        self = flags
    }
}

/// Inert semantic annotation applied to every run of the rendered string so
/// `MarkdownReconstruction` can rebuild markdown from a selection. Never
/// carries visual attributes — layout must be identical with or without it.
/// Value equality (`isEqual`/`hash`) is load-bearing: `SelectableMessageText`
/// skips storage updates when the rebuilt string `isEqual(to:)` the current
/// one, and each build creates fresh semantics objects.
final class MarkdownRunSemantics: NSObject {
    let block: BlockKind
    /// Increments at each block boundary so two adjacent blocks of the same
    /// kind (consecutive list items) stay distinguishable.
    let blockIdentity: Int
    let inline: MarkdownInlineFlags
    let link: URL?

    init(block: BlockKind, blockIdentity: Int, inline: MarkdownInlineFlags, link: URL?) {
        self.block = block
        self.blockIdentity = blockIdentity
        self.inline = inline
        self.link = link
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MarkdownRunSemantics else { return false }
        return block == other.block
            && blockIdentity == other.blockIdentity
            && inline == other.inline
            && link == other.link
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(block)
        hasher.combine(blockIdentity)
        hasher.combine(inline)
        hasher.combine(link)
        return hasher.finalize()
    }
}
