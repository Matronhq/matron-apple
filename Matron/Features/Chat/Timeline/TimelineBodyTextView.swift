import UIKit
import MatronDesignSystem

/// The text view a text row's whole `TextRowBody` lives in. Two things set
/// it apart from a plain timeline text view:
///
/// - It only takes presses that land on its text. A press on a block's
///   placeholder line goes to the code block or table drawn under it, and
///   one on blank space (between paragraphs, past the end of a short line)
///   goes to the row, whose long-press menu copies the whole message. While
///   it holds a selection it takes every press but a block's, so a tap
///   anywhere clears the selection and both handles stay in reach.
/// - Copying a selection that runs through a block (and VoiceOver reading
///   the text) puts the block's own text where its placeholder sits. The
///   block views are hidden from VoiceOver, so it reads them once, in place.
class TimelineBodyTextView: UITextView {
    var body: TextRowBody = .empty
    /// The block views' frames, in this view's coordinates.
    var blockFrames: [CGRect] = []

    /// How far beside a character a press still counts as on it.
    static let textHitSlop: CGFloat = 8
    /// How far from a selection end its handle can be grabbed.
    static let handleHitSlop: CGFloat = 24

    init() {
        super.init(frame: .zero, textContainer: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var hasSelection: Bool { isFirstResponder && selectedRange.length > 0 }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        let onBlock = blockFrames.contains { $0.contains(point) }
        if hasSelection, isNearSelectionHandle(point, onBlock: onBlock) { return true }
        if onBlock { return false }
        return hasSelection || isOnText(point)
    }

    /// Whether `point` is in reach of a selection end's handle. On a block
    /// only the handle's knob (above the start, below the end) counts: a
    /// selection ending at a block has a caret as tall as the block, and
    /// the block's copy button and scrolling stay its own beside it.
    private func isNearSelectionHandle(_ point: CGPoint, onBlock: Bool) -> Bool {
        guard let range = selectedTextRange else { return false }
        let slop = -Self.handleHitSlop
        let start = caretRect(for: range.start), end = caretRect(for: range.end)
        let reach = onBlock ? [CGRect(x: start.midX, y: start.minY, width: 0, height: 0),
                               CGRect(x: end.midX, y: end.maxY, width: 0, height: 0)]
                            : [start, end]
        return reach.contains { $0.insetBy(dx: slop, dy: slop).contains(point) }
    }

    /// Whether `point` is on (or just beside) a character of the text,
    /// a block's placeholder not counting.
    func isOnText(_ point: CGPoint) -> Bool {
        isOnGlyph(point, slop: Self.textHitSlop) { body.block(at: $0) != nil }
    }

    /// The text as read out and searched: each placeholder is its block's text.
    override var accessibilityValue: String? {
        get {
            guard !body.blocks.isEmpty else { return super.accessibilityValue }
            return body.copyText(in: NSRange(location: 0, length: body.text.length))
        }
        set { super.accessibilityValue = newValue }
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange
        guard range.length > 0, body.blocks.contains(where: { NSLocationInRange($0.location, range) }) else {
            return super.copy(sender)
        }
        Pasteboard.copy(body.copyText(in: range))
    }
}

extension UITextView {
    /// Whether `point` is on (or `slop` beside) a character of the text:
    /// one of the two characters (whole emoji, combining marks and all)
    /// either side of the closest caret position. Line breaks, and the
    /// characters `skipping` names, don't count.
    func isOnGlyph(_ point: CGPoint, slop: CGFloat, skipping: (Int) -> Bool = { _ in false }) -> Bool {
        guard let position = closestPosition(to: point) else { return false }
        let string = attributedText.string as NSString
        let offset = self.offset(from: beginningOfDocument, to: position)
        for index in [offset - 1, offset] where index >= 0 && index < string.length {
            let character = string.rangeOfComposedCharacterSequence(at: index)
            guard !skipping(character.location), string.character(at: character.location) != 0x0A,
                  let start = self.position(from: beginningOfDocument, offset: character.location),
                  let end = self.position(from: start, offset: character.length),
                  let range = textRange(from: start, to: end) else { continue }
            let rect = firstRect(for: range)
            guard !rect.isNull, !rect.isInfinite else { continue }
            if rect.insetBy(dx: -slop, dy: 0).contains(point) { return true }
        }
        return false
    }
}
