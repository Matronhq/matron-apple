import UIKit

/// Exact TextKit 2 measurement of an attributed string at a width — the same
/// engine and geometry (`lineFragmentPadding` 0, no insets) as the timeline's
/// `UITextView`s (`TimelineTextViewFactory`). A pure function of (string,
/// width), safe on any thread: each call owns a private stack.
enum TextKitMeasure {
    struct Result: Equatable {
        var size: CGSize
        /// The last line's baseline, measured from the top of the text —
        /// `MessageBubble` aligns the timestamp to it (`.lastTextBaseline`).
        var lastBaseline: CGFloat
    }

    static func measure(_ text: NSAttributedString, width: CGFloat) -> Result {
        measure(text, width: width, locating: []).result
    }

    /// `measure`, plus the laid-out bounds of each of `ranges`: the union of
    /// its line rects, at the lines' own height (what the text view
    /// highlights when the range is selected).
    static func measure(_ text: NSAttributedString, width: CGFloat,
                        locating ranges: [NSRange]) -> (result: Result, rects: [CGRect]) {
        guard text.length > 0, width > 0 else {
            return (Result(size: .zero, lastBaseline: 0), ranges.map { _ in .zero })
        }
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        storage.addTextLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        storage.attributedString = text
        manager.ensureLayout(for: manager.documentRange)

        var lastBaseline: CGFloat = 0
        manager.enumerateTextLayoutFragments(from: manager.documentRange.endLocation,
                                             options: [.reverse, .ensuresLayout]) { fragment in
            if let line = fragment.textLineFragments.last {
                lastBaseline = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
            }
            return false
        }
        let used = manager.usageBoundsForTextContainer
        let rects = ranges.map { range -> CGRect in
            guard let start = manager.location(manager.documentRange.location, offsetBy: range.location),
                  let end = manager.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return .zero }
            var union = CGRect.null
            manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                union = union.union(frame)
                return true
            }
            return union.isNull ? .zero : union
        }
        // To the right edge of the text, not the width of its ink: an
        // indented paragraph starts in from the edge, and a view as wide
        // as the ink alone would wrap it again.
        return (Result(size: CGSize(width: min(ceil(used.maxX), width), height: ceil(used.maxY)),
                       lastBaseline: lastBaseline), rects)
    }

    /// Measures at `width`, then — when the text is narrower — re-measures
    /// at its own hugged width, because that is the frame the live view
    /// gets (bubbles hug their text). Same two-pass rule as the Mac's
    /// `MarkdownAttributed.Rendered.size(width:)`.
    static func hugging(_ text: NSAttributedString, width: CGFloat) -> Result {
        let first = measure(text, width: width)
        guard first.size.width > 0, first.size.width < width.rounded(.down) else { return first }
        let rewrapped = measure(text, width: first.size.width)
        return Result(size: CGSize(width: first.size.width, height: rewrapped.size.height),
                      lastBaseline: rewrapped.lastBaseline)
    }
}

/// The one configuration every timeline text view uses — measured parity
/// (`TextKitMeasureTests.test_matchesALiveTextView`) depends on it.
enum TimelineTextViewFactory {
    @MainActor
    static func make() -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        configure(view)
        return view
    }

    @MainActor
    static func configure(_ view: UITextView) {
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = false
        view.dataDetectorTypes = []
        view.linkTextAttributes = [
            .foregroundColor: UIColor.tintColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }
}
