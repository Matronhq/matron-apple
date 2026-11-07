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
///   the text) puts the block's own text where its placeholder sits.
final class TimelineBodyTextView: UITextView {
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
        if hasSelection, isNearSelectionEnd(point) { return true }
        if blockFrames.contains(where: { $0.contains(point) }) { return false }
        return hasSelection || isOnText(point)
    }

    private func isNearSelectionEnd(_ point: CGPoint) -> Bool {
        guard let range = selectedTextRange else { return false }
        let slop = -Self.handleHitSlop
        return [range.start, range.end].contains { caretRect(for: $0).insetBy(dx: slop, dy: slop).contains(point) }
    }

    /// Whether `point` is on (or just beside) a character of the text: one
    /// of the two characters either side of the closest caret position.
    func isOnText(_ point: CGPoint) -> Bool {
        guard let position = closestPosition(to: point) else { return false }
        let string = attributedText.string as NSString
        let offset = self.offset(from: beginningOfDocument, to: position)
        for index in [offset - 1, offset] where index >= 0 && index < string.length {
            guard body.block(at: index) == nil, string.character(at: index) != 0x0A,
                  let start = self.position(from: beginningOfDocument, offset: index),
                  let end = self.position(from: start, offset: 1),
                  let range = textRange(from: start, to: end) else { continue }
            let rect = firstRect(for: range)
            guard !rect.isNull, !rect.isInfinite else { continue }
            if rect.insetBy(dx: -Self.textHitSlop, dy: 0).contains(point) { return true }
        }
        return false
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
