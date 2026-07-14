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

    /// Base body size. Mirrors `Theme.matronMessage`'s macOS scale in
    /// `MarkdownText.swift`: the system body is 13pt on macOS, scaled ×1.34 for
    /// chat message text (≈17.4pt) to match matron-web's chat body. Keep these
    /// two numbers in sync — if the theme scale changes there, change it here.
    static let baseFontSize: CGFloat = 13 * 1.34

    /// Space after a paragraph, in points — the visual gap MarkdownUI leaves
    /// between blocks.
    private static let paragraphSpacing: CGFloat = 8

    /// Hanging indent for list items and block quotes, in points.
    private static let listIndent: CGFloat = 18
    private static let quoteIndent: CGFloat = 12
    private static let codeBlockIndent: CGFloat = 8

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

    // MARK: - Height measurement

    /// Exact laid-out height of `attributed` wrapped to `width`, rounded up.
    ///
    /// Measured against a standalone TextKit stack (storage + layout manager +
    /// container) rather than a live `NSTextView`, so the result is a pure
    /// function of (attributed string, width) — no dependence on a view's frame,
    /// `widthTracksTextView`, or layout timing. This is the height
    /// `SelectableMessageText` reports to SwiftUI; keeping it deterministic is
    /// what protects the timeline from height churn.
    static func height(for attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard width > 0, width.isFinite else { return 0 }
        let textStorage = NSTextStorage(attributedString: attributed)
        let textContainer = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        // Match the live text view's geometry (see SelectableMessageText) so the
        // measured height equals the rendered height.
        textContainer.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }

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

        for run in attributed.runs {
            let intent = run.presentationIntent
            let block = BlockKind(intent)

            // Block boundary: a new `presentationIntent` identity means a new
            // block. Separate it from the previous block with a newline (the
            // per-paragraph `paragraphSpacing` supplies the visual gap) and, for
            // list items, prepend the marker.
            if previousIntent != nil, intent != previousIntent {
                output.append(NSAttributedString(string: "\n"))
            }
            if intent != previousIntent, let marker = block.marker {
                output.append(NSAttributedString(
                    string: marker,
                    attributes: runAttributes(block: block, inline: [], link: nil)
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
                    link: run.link
                )
            ))
        }

        return output
    }

    // MARK: - Attribute mapping

    /// Builds the AppKit attribute dictionary for a single run, combining its
    /// block context with its inline intents and any link.
    private static func runAttributes(
        block: BlockKind,
        inline: InlinePresentationIntent,
        link: URL?
    ) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .paragraphStyle: paragraphStyle(for: block),
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
    private static func paragraphStyle(for block: BlockKind) -> NSMutableParagraphStyle {
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
        case .header, .paragraph:
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
    /// keep it simple — h1 1.4×, h2 1.25×, h3 1.1×, h4–h6 fall back to body.
    var fontSize: CGFloat {
        switch self {
        case .header(let level):
            switch level {
            case 1: return MarkdownAttributed.baseFontSize * 1.4
            case 2: return MarkdownAttributed.baseFontSize * 1.25
            case 3: return MarkdownAttributed.baseFontSize * 1.1
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
