#if os(macOS)
import AppKit
import Foundation
import os

/// Mac-only Markdown → `NSAttributedString` converter.
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
enum MarkdownAttributed {

    // MARK: - Sizing constants

    /// Base body size: the 13pt macOS system body at the shared
    /// `MessageTextScale.scale` (≈15.3pt) — the same constant
    /// `Theme.matronMessage` uses, so this renderer and MarkdownUI's
    /// cannot drift apart in size.
    static let baseFontSize: CGFloat = 13 * MessageTextScale.scale

    /// Space after a paragraph, in points — the visual gap MarkdownUI leaves
    /// between blocks.
    private static let paragraphSpacing: CGFloat = 8

    /// Hanging indent for list items and block quotes, in points.
    private static let listIndent: CGFloat = 18
    private static let quoteIndent: CGFloat = 12
    private static let codeBlockIndent: CGFloat = 8

    /// Extra space ABOVE a heading (on top of the previous block's
    /// `paragraphSpacing`), and the reduced space below it. Headings need
    /// clear air from the section they close and should sit close to the
    /// section they open (Dan, 2026-07-15: "not enough space between the
    /// bottom of one paragraph and the heading after it"). Suppressed for
    /// a message that STARTS with a heading — no dead band at the bubble
    /// top.
    private static let headerSpacingBefore: CGFloat = 10
    private static let headerSpacingAfter: CGFloat = 6

    // MARK: - Public API

    /// Converts markdown `source` to a display-ready `NSAttributedString`.
    /// Memoised on `source` — messages are immutable, so the same body converts
    /// once; a long streaming session churns intermediate texts through the
    /// bounded cache without pinning them.
    static func attributedString(for source: String) -> NSAttributedString {
        let key = source as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let built = build(from: source)
        cache.setObject(built, forKey: key)
        return built
    }

    /// Bounded, thread-safe memo — mirrors `MarkdownText.contentCache`
    /// (countLimit 400, evicts under memory pressure).
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 400
        return cache
    }()

    private static let log = Logger(subsystem: "chat.matron", category: "MarkdownAttributed")

    // MARK: - Size measurement

    /// Exact laid-out size of `attributed` wrapped to `proposedWidth`.
    ///
    /// Width is the CONTENT's natural width (longest line fragment, rounded
    /// up), never the proposal — that's what lets a short message's bubble hug
    /// its text instead of spanning the pane. Height is re-measured at that
    /// hugged width so the reported (width, height) pair is exactly what the
    /// live text view will render.
    ///
    /// Measured against a standalone TextKit stack rather than a live
    /// `NSTextView`, so the result is a pure function of (attributed string,
    /// width) — no dependence on a view's frame, `widthTracksTextView`, or
    /// layout timing. This is the size `SelectableMessageText` reports to
    /// SwiftUI; keeping it deterministic is what protects the timeline from
    /// height churn.
    ///
    /// Memoised: SwiftUI calls `sizeThatFits` for every visible row on every
    /// layout pass, and the timeline is deliberately non-lazy (blank-chat
    /// cure), so an uncached TextKit layout here ran ~120 full measurements
    /// per scroll tick — the 2026-07 Mac scroll lag.
    static func size(for attributed: NSAttributedString, source: String, width proposedWidth: CGFloat) -> CGSize {
        guard proposedWidth > 0, proposedWidth.isFinite else { return .zero }
        let key = "\(proposedWidth)|\(source)" as NSString
        if let hit = sizeCache.object(forKey: key) { return hit.sizeValue }

        let first = layoutSize(for: attributed, width: proposedWidth)
        var result = first
        // Hug: if the content is narrower than the proposal, re-wrap at the
        // hugged width so the height matches what the view renders at that
        // width (the ceil can shift a wrap boundary; measuring twice removes
        // the guess).
        if first.width < proposedWidth.rounded(.down) {
            let rewrapped = layoutSize(for: attributed, width: first.width)
            result = CGSize(width: first.width, height: rewrapped.height)
        }
        sizeCache.setObject(NSValue(size: result), forKey: key)
        return result
    }

    /// One uncached TextKit layout pass: natural width (≤ `width`) and height.
    private static func layoutSize(for attributed: NSAttributedString, width: CGFloat) -> CGSize {
        let textStorage = NSTextStorage(attributedString: attributed)
        let textContainer = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        // Match the live text view's geometry (see SelectableMessageText) so the
        // measured size equals the rendered size.
        textContainer.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(width: min(ceil(used.width), width), height: ceil(used.height))
    }

    /// Memo for `size(for:source:width:)`, keyed on (proposed width, markdown
    /// SOURCE). The source — not the attributed string's rendered text —
    /// identifies the attributes: `**hi**` and `hi` render the same plain
    /// characters with different fonts, so a rendered-text key would let one
    /// message reuse the other's size (bugbot, PR #37). Conversion is a pure
    /// function of source, so (source, width) → size is collision-free.
    /// Generous bound — entries are one NSValue each; the key dominates, and
    /// 2000 keys of chat-message length is still small.
    private static let sizeCache: NSCache<NSString, NSValue> = {
        let cache = NSCache<NSString, NSValue>()
        cache.countLimit = 2000
        return cache
    }()

    // MARK: - Conversion

    private static func build(from source: String) -> NSAttributedString {
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
                    .font: font(size: baseFontSize),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraphStyle(for: .paragraph),
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

        for run in attributed.runs {
            let intent = run.presentationIntent
            let block = BlockKind(intent)

            // Block boundary: a new `presentationIntent` identity means a new
            // block. Separate it from the previous block with a newline (the
            // per-paragraph `paragraphSpacing` supplies the visual gap) and, for
            // list items, prepend the marker. Skipped when the previous block
            // already ends with its own newline — a fenced code block's run
            // text keeps the parser's trailing "\n", and doubling it rendered
            // an empty code-styled line between the block and the next
            // paragraph (Dan, 2026-07-16).
            if previousIntent != nil, intent != previousIntent {
                if !output.string.hasSuffix("\n") {
                    output.append(NSAttributedString(string: "\n"))
                }
                isFirstBlock = false
            }
            if intent != previousIntent, let marker = block.marker {
                output.append(NSAttributedString(
                    string: marker,
                    attributes: runAttributes(block: block, inline: [], link: nil, isFirstBlock: isFirstBlock)
                ))
            }
            previousIntent = intent

            let text = String(attributed[run.range].characters)
            guard !text.isEmpty else { continue }
            output.append(NSAttributedString(
                string: text,
                attributes: runAttributes(
                    block: block,
                    inline: run.inlinePresentationIntent ?? [],
                    link: run.link,
                    isFirstBlock: isFirstBlock
                )
            ))
        }

        // Never end on a newline: a message whose LAST block is a fenced code
        // block otherwise carries the parser's trailing "\n" into layout as
        // an empty monospaced line + paragraph spacing — ~25pt of dead space
        // at the bottom of the bubble, and plan-style messages very often
        // end with a code block (Dan, 2026-07-16). Interior newlines are
        // untouched; only the string's tail is trimmed.
        while output.length > 0, output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }

        return output
    }

    // MARK: - Attribute mapping

    /// Builds the AppKit attribute dictionary for a single run, combining its
    /// block context with its inline intents and any link.
    private static func runAttributes(
        block: BlockKind,
        inline: InlinePresentationIntent,
        link: URL?,
        isFirstBlock: Bool = false
    ) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .paragraphStyle: paragraphStyle(for: block, isFirstBlock: isFirstBlock),
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
            size = block.fontSize * 0.92
        } else {
            size = block.fontSize
        }

        attrs[.font] = font(size: size, bold: isBold, italic: isItalic, monospaced: isCode)
        attrs[.foregroundColor] = block.foreground

        // Inline-code / code-block background. Uses `controlBackgroundColor` to
        // match the `.matronInlineCodeBg` / `.matronCodeBg` aliases at the
        // bottom of `MarkdownText.swift`.
        if isCode {
            attrs[.backgroundColor] = NSColor.controlBackgroundColor
        }

        if inline.contains(.strikethrough) {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        if let link {
            // Mirror `MarkdownText.handle(url:)`'s policy: matrix-internal
            // schemes never become clickable links (there's no in-app handler
            // yet), so they render as plain accent text with no `.link`
            // attribute. Everything else gets an accent-coloured, underlined,
            // clickable link.
            switch link.scheme?.lowercased() {
            case "matrix", "mxc":
                attrs[.foregroundColor] = NSColor.controlAccentColor
            default:
                attrs[.link] = link
                attrs[.foregroundColor] = NSColor.controlAccentColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
        }

        return attrs
    }

    /// Paragraph style for a block: shared body spacing plus block-specific
    /// indents. A fresh instance per run keeps the styles value-safe.
    private static func paragraphStyle(for block: BlockKind, isFirstBlock: Bool = false) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        switch block {
        case .listItem:
            // Hanging indent so wrapped lines align past the marker.
            style.headIndent = listIndent
            style.paragraphSpacing = 2
        case .blockQuote:
            style.headIndent = quoteIndent
            style.firstLineHeadIndent = quoteIndent
            style.paragraphSpacing = paragraphSpacing
        case .codeBlock:
            style.headIndent = codeBlockIndent
            style.firstLineHeadIndent = codeBlockIndent
            style.paragraphSpacing = paragraphSpacing
        case .header:
            // Air above (unless the message opens with the heading — no
            // dead band at the bubble top), tighter attachment below.
            style.paragraphSpacingBefore = isFirstBlock ? 0 : headerSpacingBefore
            style.paragraphSpacing = headerSpacingAfter
        case .paragraph:
            style.paragraphSpacing = paragraphSpacing
        }
        return style
    }

    /// Resolves an AppKit font for the requested traits. System font for body
    /// text, monospaced system font for code, applied via symbolic traits so the
    /// resulting descriptor reliably reports `.bold` / `.italic` (weight-based
    /// bold doesn't guarantee the symbolic trait is set).
    private static func font(
        size: CGFloat,
        bold: Bool = false,
        italic: Bool = false,
        monospaced: Bool = false
    ) -> NSFont {
        let base: NSFont = monospaced
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size)

        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return base }

        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

// MARK: - Block classification

/// The subset of block-level markdown structure this converter renders,
/// distilled from a run's `PresentationIntent`. Carries the derived font size,
/// colour, weight, and (for lists) the marker to prepend.
private enum BlockKind {
    case paragraph
    case header(level: Int)
    case codeBlock
    case blockQuote
    /// `ordinal` is `nil` for unordered items (renders "• ") and the 1-based
    /// number for ordered items (renders "N. ").
    case listItem(ordinal: Int?)

    init(_ intent: PresentationIntent?) {
        guard let components = intent?.components else {
            self = .paragraph
            return
        }
        // Inspect the block's intent components (a run can be nested, e.g. a
        // paragraph inside a list item inside a list). Order the checks from
        // most- to least-specific structural kind.
        var listOrdinal: Int?
        var isOrdered = false
        var sawListItem = false

        for component in components {
            switch component.kind {
            case .header(let level):
                self = .header(level: level)
                return
            case .codeBlock:
                self = .codeBlock
                return
            case .blockQuote:
                self = .blockQuote
                return
            case .listItem(let ordinal):
                sawListItem = true
                listOrdinal = ordinal
            case .orderedList:
                isOrdered = true
            default:
                break
            }
        }

        if sawListItem {
            self = .listItem(ordinal: isOrdered ? listOrdinal : nil)
        } else {
            self = .paragraph
        }
    }

    /// Base font size for the block. Headers step up over the body size;
    /// keep it simple — h1 1.3×, h2 1.15×, h3 1.05×, h4–h6 fall back to
    /// body. (Walked down from 1.4/1.25/1.1 — headings read oversized
    /// inside chat bubbles; Dan, 2026-07-15.)
    var fontSize: CGFloat {
        switch self {
        case .header(let level):
            switch level {
            case 1: return MarkdownAttributed.baseFontSize * 1.3
            case 2: return MarkdownAttributed.baseFontSize * 1.15
            case 3: return MarkdownAttributed.baseFontSize * 1.05
            default: return MarkdownAttributed.baseFontSize
            }
        default:
            return MarkdownAttributed.baseFontSize
        }
    }

    /// Headers render bold.
    var isBold: Bool {
        if case .header = self { return true }
        return false
    }

    var isCodeBlock: Bool {
        if case .codeBlock = self { return true }
        return false
    }

    /// Text colour: block quotes read as secondary; everything else is the
    /// primary label colour.
    var foreground: NSColor {
        switch self {
        case .blockQuote: return .secondaryLabelColor
        default: return .labelColor
        }
    }

    /// Marker prepended at the start of a list item ("• " / "N. "). `nil` for
    /// every other block.
    var marker: String? {
        guard case .listItem(let ordinal) = self else { return nil }
        if let ordinal { return "\(ordinal). " }
        return "\u{2022} "
    }
}
#endif
