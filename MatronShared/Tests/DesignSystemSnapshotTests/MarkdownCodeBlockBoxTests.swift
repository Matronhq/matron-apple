#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import MatronDesignSystem

/// A fenced code block renders as ONE box: no paragraph gap or extra leading
/// between its lines (each "\n"-terminated line is its own TextKit
/// paragraph, and the block-wide style used to put the body's paragraph
/// spacing under every one of them), no per-glyph background strips, and a
/// single background the text view draws from its own live layout.
@MainActor
final class MarkdownCodeBlockBoxTests: XCTestCase {
    private static let diagram = """
    Intro paragraph.

    ```
    ┌──────────┬──────────┐
    │ Latest   │ Needs you│
    └──────────┴──────────┘
    ```

    After the diagram.
    """

    private let padding = MarkdownAttributed.codeBlockPadding

    // MARK: - Attributed output

    private func paragraphStyle(_ attributed: NSAttributedString, atFirst needle: String) -> NSParagraphStyle {
        let range = (attributed.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "missing \(needle)")
        return attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as! NSParagraphStyle
    }

    func test_codeLines_haveNoSpacingInside_andTheBlockGapAfterTheLastLine() {
        for style in [MarkdownAttributed.Style.chat, .item] {
            let attributed = MarkdownAttributed.attributedString(for: Self.diagram, style: style)
            let first = paragraphStyle(attributed, atFirst: "┌")
            let middle = paragraphStyle(attributed, atFirst: "│ Latest")
            let last = paragraphStyle(attributed, atFirst: "└")

            XCTAssertEqual(first.paragraphSpacingBefore, padding)
            XCTAssertEqual(first.paragraphSpacing, 0, "gap under the first code line")
            XCTAssertEqual(middle.paragraphSpacingBefore, 0)
            XCTAssertEqual(middle.paragraphSpacing, 0, "gap under an interior code line")
            XCTAssertEqual(last.paragraphSpacingBefore, 0)
            XCTAssertEqual(last.paragraphSpacing, style.paragraphSpacing + padding,
                           "only the block's last line carries the paragraph gap (plus the box padding)")
            for line in [first, middle, last] {
                XCTAssertEqual(line.lineSpacing, 0, "code lines take no extra leading")
                XCTAssertGreaterThan(line.headIndent, line.firstLineHeadIndent,
                                     "a wrapped code line hangs further in than its first fragment")
            }
            // Prose around the block keeps the render style's metrics.
            XCTAssertEqual(paragraphStyle(attributed, atFirst: "Intro").paragraphSpacing, style.paragraphSpacing)
            XCTAssertEqual(paragraphStyle(attributed, atFirst: "Intro").lineSpacing, style.lineSpacing)
        }
    }

    func test_singleLineBlock_isBothFirstAndLast() {
        let attributed = MarkdownAttributed.attributedString(for: "Before.\n\n```\nmake test\n```\n\nAfter.", style: .item)
        let line = paragraphStyle(attributed, atFirst: "make test")
        XCTAssertEqual(line.paragraphSpacingBefore, padding)
        XCTAssertEqual(line.paragraphSpacing, MarkdownAttributed.Style.item.paragraphSpacing + padding)
    }

    /// The per-glyph background painted each line as its own strip with a
    /// gap between them; the block's box is drawn by the text view instead.
    /// Inline code keeps its glyph background.
    func test_codeBlock_carriesNoGlyphBackground_inlineCodeStillDoes() {
        let attributed = MarkdownAttributed.attributedString(
            for: "Run `npm ci` first.\n\n```\nline one\nline two\n```", style: .item)
        let code = (attributed.string as NSString).range(of: "line one\nline two")
        attributed.enumerateAttribute(.backgroundColor, in: code) { value, range, _ in
            XCTAssertNil(value, "code block glyphs at \(range) carry a background")
        }
        let inline = (attributed.string as NSString).range(of: "npm ci")
        XCTAssertNotNil(attributed.attribute(.backgroundColor, at: inline.location, effectiveRange: nil))
    }

    // MARK: - Edge inset and measured size

    func test_codeEdgeInset_onlyWhenAMessageStartsOrEndsWithCode() {
        XCTAssertEqual(MarkdownAttributed.rendered(for: Self.diagram, style: .item).codeEdgeInset, 0)
        XCTAssertEqual(MarkdownAttributed.rendered(for: "```\nx\n```\n\nAfter.", style: .item).codeEdgeInset, padding)
        XCTAssertEqual(MarkdownAttributed.rendered(for: "Before.\n\n```\nx\n```", style: .item).codeEdgeInset, padding)
        XCTAssertEqual(MarkdownAttributed.rendered(for: "No code at all.", style: .item).codeEdgeInset, 0)
    }

    /// A message that is only a code block is indented throughout; the hug
    /// width used to drop that indent, so the view re-wrapped every line.
    func test_codeOnlyMessage_huggedWidthKeepsItsLinesUnwrapped() {
        let rendered = MarkdownAttributed.rendered(for: "```\nline one\nline two\n```", style: .chat)
        let size = rendered.size(width: 400)
        let wide = rendered.size(width: 2000)
        XCTAssertEqual(size.height, wide.height, "hugged width wrapped the code lines")
        let lineHeight = MarkdownAttributed.rendered(for: "```\nline one\n```", style: .chat).size(width: 400).height
            - 2 * padding
        XCTAssertEqual(size.height, 2 * lineHeight + 2 * padding, accuracy: 0.5,
                       "two unwrapped lines plus the edge inset above and below")
    }

    /// When a code line is the widest content, the hugged width leaves the
    /// box's padding past its last glyph instead of ending flush against it.
    func test_huggedWidth_reservesPaddingPastTheWidestCodeLine() {
        let code = MarkdownAttributed.rendered(for: "Hi.\n\n```\nlet longestLine = 1\n```", style: .chat)
        let codeOnlyWidth = MarkdownAttributed.rendered(for: "```\nlet longestLine = 1\n```", style: .chat)
            .size(width: 1000).width
        XCTAssertEqual(code.size(width: 1000).width, codeOnlyWidth)
        let (window, textView) = host("Hi.\n\n```\nlet longestLine = 1\n```", width: nil)
        defer { window.close() }
        // Glyph extent of the code line at the view's (hugged) width.
        let frames = MarkdownAttributed.rendered(for: "Hi.\n\n```\nlet longestLine = 1\n```", style: .item)
            .codeBlockFrames(width: textView.bounds.width)
        XCTAssertEqual(frames.count, 1)
        guard let frame = frames.first else { return }
        XCTAssertLessThan(frame.rect.height, 2 * 15, "the code line wrapped at the hugged width")
        XCTAssertGreaterThanOrEqual(textView.bounds.width - frame.rect.maxX, padding - 0.5,
                                    "no room between the widest code line and the box edge")
    }

    // MARK: - Live text view geometry

    /// `width: nil` leaves the view at its hugged natural width.
    private func host(_ source: String, width: CGFloat? = 360, defersTextView: Bool = false) -> (NSWindow, MessageCopyTextView) {
        let hosting = NSHostingView(rootView:
            SelectableMessageText(source, style: .item, defersTextView: defersTextView)
                .frame(width: width, alignment: .topLeading)
                .frame(maxWidth: 500, alignment: .topLeading))
        // A hugged view needs a width proposal to hug within (it reports
        // no size without one), so give the host a fixed frame.
        hosting.frame = width == nil ? NSRect(x: 0, y: 0, width: 500, height: 400)
                                     : NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        func find(_ view: NSView) -> MessageCopyTextView? {
            if let textView = view as? MessageCopyTextView { return textView }
            return view.subviews.lazy.compactMap(find).first
        }
        return (window, find(hosting)!)
    }

    /// The laid-out line rect holding `needle`'s first character, in the text
    /// view's coordinates — from `firstRect(forCharacterRange:)`, which is
    /// answered by whichever TextKit engine the view runs.
    private func lineRect(_ textView: MessageCopyTextView, _ needle: String) -> NSRect {
        let range = (textView.string as NSString).range(of: needle)
        let screen = textView.firstRect(forCharacterRange: NSRange(location: range.location, length: 1), actualRange: nil)
        return textView.convert(textView.window!.convertFromScreen(screen), from: nil)
    }

    private func assertOneBoxHugsTheLines(_ textView: MessageCopyTextView, first: String, last: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let boxes = textView.codeBlockBoxes()
        XCTAssertEqual(boxes.count, 1, "one box per fenced block", file: file, line: line)
        guard let box = boxes.first else { return }
        let top = lineRect(textView, first)
        let bottom = lineRect(textView, last)
        XCTAssertEqual(box.minX, 0, file: file, line: line)
        XCTAssertEqual(box.width, textView.bounds.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(box.minY, top.minY - padding, accuracy: 1, "box top padding", file: file, line: line)
        XCTAssertEqual(box.maxY, bottom.maxY + padding, accuracy: 1, "box bottom padding", file: file, line: line)
        XCTAssertGreaterThanOrEqual(box.minY, -0.5, "box clipped at the view top", file: file, line: line)
        XCTAssertLessThanOrEqual(box.maxY, textView.bounds.height + 0.5, "box clipped at the view bottom",
                                 file: file, line: line)
    }

    func test_textKit2_oneBoxAroundTheLiveLines_withNoGapsBetweenThem() {
        let (window, textView) = host(Self.diagram)
        defer { window.close() }
        XCTAssertNotNil(textView.textLayoutManager, "precondition: TextKit 2")
        assertOneBoxHugsTheLines(textView, first: "┌", last: "└")
        let a = lineRect(textView, "┌"), b = lineRect(textView, "│ Latest"), c = lineRect(textView, "└")
        XCTAssertEqual(b.minY, a.maxY, accuracy: 0.5, "gap between code lines 1 and 2")
        XCTAssertEqual(c.minY, b.maxY, accuracy: 0.5, "gap between code lines 2 and 3")
    }

    /// Tables switch the view to TextKit 1 before layout; the box must come
    /// from that engine's layout just the same.
    func test_textKit1_tabledMessage_oneBoxAroundTheLiveLines() {
        let (window, textView) = host(Self.diagram + "\n\n| A | B |\n|---|---|\n| 1 | 2 |")
        defer { window.close() }
        XCTAssertNil(textView.textLayoutManager, "precondition: TextKit 1")
        assertOneBoxHugsTheLines(textView, first: "┌", last: "└")
    }

    /// TextKit drops a document's leading `paragraphSpacingBefore` and never
    /// counts its trailing `paragraphSpacing`; the edge inset keeps the box
    /// inside the view at both message edges.
    func test_blockAtMessageEdges_keepsItsPaddingInsideTheView() {
        let (startWindow, startsWithCode) = host("```\nfirst\nsecond\n```\n\nAfter.")
        defer { startWindow.close() }
        assertOneBoxHugsTheLines(startsWithCode, first: "first", last: "second")

        let (endWindow, endsWithCode) = host("Before.\n\n```\nfirst\nsecond\n```")
        defer { endWindow.close() }
        assertOneBoxHugsTheLines(endsWithCode, first: "first", last: "second")
        XCTAssertEqual(endsWithCode.codeBlockBoxes().first?.maxY ?? 0, endsWithCode.bounds.height, accuracy: 1,
                       "the box closes at the view's bottom edge")
    }

    func test_twoBlocks_twoBoxes_noCodeNoBoxes() {
        let (window, textView) = host("```\na\n```\n\nBetween.\n\n```\nb\nc\n```")
        defer { window.close() }
        let boxes = textView.codeBlockBoxes()
        XCTAssertEqual(boxes.count, 2)
        if boxes.count == 2 { XCTAssertLessThan(boxes[0].maxY, boxes[1].minY, "boxes must not overlap") }

        let (plainWindow, plain) = host("Just prose with `inline code`.")
        defer { plainWindow.close() }
        XCTAssertTrue(plain.codeBlockBoxes().isEmpty)
    }

    /// A blank line before the closing fence is code; it stays inside the
    /// box instead of hanging below it.
    func test_trailingBlankLineInsideAFence_staysInTheBox() {
        let (window, textView) = host("Before.\n\n```\nline\n\n```\n\nAfter.")
        defer { window.close() }
        guard let box = textView.codeBlockBoxes().first else { return XCTFail("no box") }
        let line = lineRect(textView, "line")
        let blankLine = (textView.string as NSString).range(of: "line\n").location + 5
        let screen = textView.firstRect(forCharacterRange: NSRange(location: blankLine, length: 0), actualRange: nil)
        let blank = textView.convert(textView.window!.convertFromScreen(screen), from: nil)
        XCTAssertGreaterThan(blank.minY, line.minY, "precondition: the blank line sits below the code line")
        XCTAssertGreaterThanOrEqual(box.maxY, blank.minY + line.height + padding - 1, "blank code line outside the box")
        XCTAssertLessThan(box.maxY, lineRect(textView, "After").minY, "box runs into the next paragraph")
    }

    /// The boxes are cached per width; a resize must move them.
    func test_boxesFollowAWidthChange() {
        let (window, textView) = host(Self.diagram)
        defer { window.close() }
        XCTAssertEqual(textView.codeBlockBoxes().first?.width ?? 0, textView.bounds.width, accuracy: 0.5)
        textView.setFrameSize(NSSize(width: textView.bounds.width - 60, height: textView.bounds.height))
        XCTAssertEqual(textView.codeBlockBoxes().first?.width ?? 0, textView.bounds.width, accuracy: 0.5)
    }

    // MARK: - Copy button

    /// The copy button is placed from `Rendered.codeBlockFrames`, measured
    /// on the engine the live view runs; it must sit on the live box's first
    /// line (a TextKit-1 measurement sat ~4pt off a TextKit 2 view).
    func test_copyButtonGeometry_matchesTheLiveBox_underBothEngines() {
        for source in [Self.diagram, Self.diagram + "\n\n| A | B |\n|---|---|\n| 1 | 2 |",
                       "```\nfirst\nsecond\n```\n\nAfter."] {
            let (window, textView) = host(source)
            defer { window.close() }
            let frames = MarkdownAttributed.rendered(for: source, style: .item).codeBlockFrames(width: textView.bounds.width)
            let boxes = textView.codeBlockBoxes()
            XCTAssertEqual(frames.count, boxes.count, "\(source.prefix(12)) w=\(textView.bounds.width) tk\(textView.textLayoutManager == nil ? 1 : 2)")
            for (frame, box) in zip(frames, boxes) {
                XCTAssertEqual(frame.rect.minY, box.minY + padding, accuracy: 1,
                               "copy-button geometry off the live box (TK\(textView.textLayoutManager == nil ? 1 : 2))")
                XCTAssertEqual(frame.rect.maxY, box.maxY - padding, accuracy: 1)
            }
        }
    }

    /// A deferred body (the item thread) always runs TextKit 1, table or
    /// not, so its copy buttons must be measured on TextKit 1 too — the
    /// overlay passes the engine instead of letting `containsTable` pick
    /// one (review).
    func test_copyButtonGeometry_matchesTheLiveBox_whenDeferred() {
        for source in [Self.diagram, "Some prose first.\n\n```\nfirst\nsecond\n```\n\nAfter."] {
            let (window, textView) = host(source, defersTextView: true)
            defer { window.close() }
            XCTAssertNil(textView.textLayoutManager, "precondition: a deferred body runs TextKit 1")
            let frames = MarkdownAttributed.rendered(for: source, style: .item)
                .codeBlockFrames(width: textView.bounds.width, textKit1: true)
            let boxes = textView.codeBlockBoxes()
            XCTAssertEqual(frames.count, boxes.count)
            for (frame, box) in zip(frames, boxes) {
                XCTAssertEqual(frame.rect.minY, box.minY + padding, accuracy: 1, "copy-button geometry off the live box")
                XCTAssertEqual(frame.rect.maxY, box.maxY - padding, accuracy: 1)
            }
        }
    }

    // MARK: - Pointer in the edge inset

    /// A code-first message carries a top container inset; a pointer in it
    /// is above the first line and must resolve to the START (TextKit 2
    /// answers the document end for any point above the first line).
    func test_pointInTheTopInset_resolvesToTheStart() {
        let (window, textView) = host("```\nfirst line of code\nsecond\n```\n\nAfter the block.")
        defer { window.close() }
        XCTAssertEqual(textView.textContainerOrigin.y, padding, "precondition: code-first message has a top inset")
        for y: CGFloat in [0.5, 3, 5.5] {
            XCTAssertEqual(textView.characterIndex(atViewPoint: NSPoint(x: 40, y: y)), 0, "y=\(y)")
        }
    }

    /// The cross-message drag: dragging down from a prose message into a
    /// code-first message, 3pt below its top edge, selects nothing of it —
    /// the head is the code message's start, not its end.
    func test_crossDragEnteringACodeFirstMessageAtY3_headIsItsStart() {
        let controller = MessageSelectionController()
        controller.orderedIDs = ["a", "b"]
        let hosting = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 20) {
                SelectableMessageText("A prose message above.", itemID: "a", style: .item)
                SelectableMessageText("```\nlet x = 1\nlet y = 2\n```\n\nAfter.", itemID: "b", style: .item)
            }
            .environment(controller)
            .frame(width: 360, alignment: .topLeading))
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        func all(_ view: NSView) -> [MessageCopyTextView] {
            (view as? MessageCopyTextView).map { [$0] } ?? view.subviews.flatMap(all)
        }
        guard let code = all(hosting).first(where: { $0.selectionItemID == "b" }) else { return XCTFail("no b") }

        XCTAssertTrue(controller.beginCrossMessage(anchorID: "a", charIndex: 0))
        let point = code.convert(NSPoint(x: 40, y: 3), to: nil)
        controller.extend(toWindowPoint: point, window: window)
        XCTAssertEqual(code.crossSelectionRange?.length ?? 0, 0,
                       "drag head jumped to the end of the code-first message")
    }

    // MARK: - On screen

    /// The box as the window server shows it: a pixel column through the
    /// block, right of every glyph, is tinted without a break from the box's
    /// top to its bottom (the old per-line strips left white gaps), and the
    /// card stays white just outside it. Skips on a headless runner.
    func test_boxPaintsContinuouslyOnScreen() throws {
        // Long prose widens the view past the short code lines, leaving a
        // glyph-free column inside the box to sample.
        let source = "An intro paragraph long enough to run the full width of the card.\n\n```\nab\ncd\nef\ngh\n```\n\nAfter."
        let hosting = NSHostingView(rootView:
            SelectableMessageText(source, style: .item)
                .frame(width: 300, alignment: .topLeading).padding(20).background(Color.white))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 340, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))

        func find(_ view: NSView) -> MessageCopyTextView? {
            if let textView = view as? MessageCopyTextView { return textView }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let textView = find(hosting), let box = textView.codeBlockBoxes().first else {
            return XCTFail("no text view / no box")
        }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]),
              image.width > 0, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            throw XCTSkip("window capture unavailable (headless runner)")
        }
        let scale = CGFloat(image.width) / window.frame.width
        func luma(_ point: NSPoint) -> Int {
            let inWindow = textView.convert(point, to: nil)
            let x = Int(inWindow.x * scale)
            let y = Int((window.frame.height - inWindow.y) * scale)
            let offset = y * image.bytesPerRow + x * 4
            return (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
        }
        XCTAssertGreaterThan(box.width, 200, "precondition: the view spans the card")
        let x = box.maxX - 30
        var y = box.minY + 2
        while y < box.maxY - 2 {
            let value = luma(NSPoint(x: x, y: y))
            XCTAssertTrue((200...250).contains(value), "untinted pixel inside the box at y=\(y): \(value)")
            y += 1
        }
        XCTAssertGreaterThan(luma(NSPoint(x: x, y: box.minY - 3)), 250, "tint above the box")
        XCTAssertGreaterThan(luma(NSPoint(x: x, y: box.maxY + 3)), 250, "tint below the box")
    }
}

/// `Theme.matronItem`'s table cells lay out at their natural width capped at
/// `ItemTypography.tableCellMaxWidth` — inside the table's horizontal
/// scroll view the grid proposes no width, and a plain `Text` would run a
/// long cell out on one line.
@MainActor
final class ItemTableCellWidthTests: XCTestCase {
    private func size(_ text: String, proposal: CGFloat? = nil) -> CGSize {
        let cell = ItemTableCellWidth(maxWidth: 120) { Text(text).fixedSize(horizontal: false, vertical: true) }
        let hosting = NSHostingController(rootView: cell)
        return hosting.sizeThatFits(in: CGSize(width: proposal ?? .infinity, height: .infinity))
    }

    func test_shortCell_hugsItsText() {
        let short = size("72")
        XCTAssertLessThan(short.width, 40)
    }

    func test_longCell_wrapsAtTheCap_withAnUnspecifiedWidth() {
        let oneLine = size("x").height
        let long = size("backfilled 72, cost re-snapshotted as v3, and several more words besides")
        XCTAssertLessThanOrEqual(long.width, 120)
        XCTAssertGreaterThan(long.height, oneLine * 1.5, "long cell did not wrap")
    }

    func test_narrowerColumnProposal_wins() {
        let narrow = size("backfilled 72, cost re-snapshotted", proposal: 60)
        XCTAssertLessThanOrEqual(narrow.width, 60)
    }
}
#endif
