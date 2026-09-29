#if os(macOS)
import XCTest
import AppKit
@testable import MatronDesignSystem

@MainActor final class MessageBodyViewTests: XCTestCase {
    func test_codeButtonsSitAtCodeBlockFrames() {
        let source = "Before\n\n```\nmake test\n```\n\nAfter"
        let rendered = MarkdownAttributed.rendered(for: source, style: .chat)
        let view = MessageBodyView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: rendered.size(width: 400).height)
        view.configure(source: source, rendered: rendered, itemID: "m1", selectionController: nil)
        view.layoutSubtreeIfNeeded()
        let buttons = view.subviews.compactMap { $0 as? NSButton }
        let frames = rendered.codeBlockFrames(width: 400)
        XCTAssertEqual(buttons.count, frames.count)
        // Same centre rule as the SwiftUI overlay: x = min(maxX + 12, width - 12), y = minY + 12.
        XCTAssertEqual(buttons[0].frame.midX, min(frames[0].rect.maxX + 12, 400 - 12), accuracy: 0.5)
        XCTAssertEqual(buttons[0].frame.midY, frames[0].rect.minY + 12, accuracy: 0.5)
    }

    /// Perf follow-ups S3: a host can switch the code-copy buttons off (a
    /// streaming body) and back on (the view reused for a finished message).
    func test_codeButtonsFollowShowsCodeCopyButtons() {
        let source = "Before\n\n```\nmake test\n```\n\nAfter"
        let rendered = MarkdownAttributed.rendered(for: source, style: .chat)
        let view = MessageBodyView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: rendered.size(width: 400).height)
        view.showsCodeCopyButtons = false
        view.configure(source: source, rendered: rendered, itemID: "m1", selectionController: nil)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.subviews.filter { $0 is NSButton }.count, 0)

        view.showsCodeCopyButtons = true
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.subviews.filter { $0 is NSButton }.count, 1)

        view.showsCodeCopyButtons = false
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.subviews.filter { $0 is NSButton }.count, 0)
    }

    /// Review gap 7e: the storage OBJECT never changes (a text view keeps
    /// its storage for life), so identity proved nothing. Count the edits
    /// it processes instead: a same-`Rendered` reconfigure makes none, a new
    /// `Rendered` makes one.
    func test_reconfigureWithSameRenderedDoesNotRewriteStorage() throws {
        let rendered = MarkdownAttributed.rendered(for: "Hi", style: .chat)
        let view = MessageBodyView()
        view.configure(source: "Hi", rendered: rendered, itemID: "m1", selectionController: nil)
        let storage = try XCTUnwrap(view.textView.textStorage)
        var edits = 0
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                              object: storage, queue: nil) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        view.textView.setSelectedRange(NSRange(location: 0, length: 1))
        view.configure(source: "Hi", rendered: rendered, itemID: "m1", selectionController: nil)
        XCTAssertEqual(edits, 0)
        XCTAssertEqual(view.textView.selectedRange().length, 1)

        // The counter does see a real rewrite.
        let next = MarkdownAttributed.rendered(for: "Hi there", style: .chat)
        view.configure(source: "Hi there", rendered: next, itemID: "m1", selectionController: nil)
        XCTAssertGreaterThan(edits, 0)
        XCTAssertEqual(view.textView.string, "Hi there")
    }

    /// Perf follow-ups X1: a message body is never edited, so no text
    /// checking runs on it (TK2 viewport layout would otherwise queue spell
    /// and text-replacement checks for every recycled body).
    func test_configuredBodyHasEveryTextCheckingFeatureOff() {
        let rendered = MarkdownAttributed.rendered(for: "Teh quick -- \"fox\" at 10am, see apple.com", style: .chat)
        let view = MessageBodyView()
        view.configure(source: "x", rendered: rendered, itemID: "m1", selectionController: nil)
        let textView = view.textView
        XCTAssertEqual(textView.enabledTextCheckingTypes, 0)
        XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(textView.isGrammarCheckingEnabled)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticDataDetectionEnabled)
        XCTAssertFalse(textView.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(textView.isAutomaticLinkDetectionEnabled)
    }

    func test_prepareForReuseClearsSelectionAndId() {
        let rendered = MarkdownAttributed.rendered(for: "Hello there", style: .chat)
        let view = MessageBodyView()
        view.configure(source: "Hello there", rendered: rendered, itemID: "m1", selectionController: nil)
        view.textView.setSelectedRange(NSRange(location: 0, length: 5))
        view.prepareForReuse()
        XCTAssertEqual(view.textView.selectedRange().length, 0)
        XCTAssertNil(view.itemID)
    }

    /// Final review minor 2: a recycled body registers with the selection
    /// AFTER its storage is replaced, so a mid-selection span is sized to
    /// the NEW message, not the one the view showed before.
    func test_recycledBodyTakesTheSpanOfItsNewLength() throws {
        final class Edge: CrossSelectionTarget {
            let selectionItemID: String?
            let frameInWindow: NSRect
            init(_ id: String, y: CGFloat) { selectionItemID = id; frameInWindow = NSRect(x: 0, y: y, width: 100, height: 20) }
            var storageLength: Int { 4 }
            func characterIndex(atWindowPoint point: NSPoint) -> Int { 2 }
            func setCrossSelection(_ range: NSRange?) {}
            func crossSelectionMarkdown() -> String { "" }
        }
        let selection = MessageSelectionController()
        selection.orderedIDs = ["a", "m1", "m2", "z"]
        // `m2` is unmounted when the selection is made: the provider sizes it.
        selection.contentProvider = { id in id == "m2" ? (NSAttributedString(string: "x"), "x") : nil }
        let a = Edge("a", y: 200), z = Edge("z", y: 0)
        selection.register(a); selection.register(z)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let view = MessageBodyView()
        view.frame = NSRect(x: 0, y: 100, width: 400, height: 40)
        window.contentView?.addSubview(view)
        let short = MarkdownAttributed.rendered(for: "short", style: .chat)
        view.configure(source: "short", rendered: short, itemID: "m1", selectionController: selection)

        XCTAssertTrue(selection.beginCrossMessage(anchorID: "a", charIndex: 2))
        selection.hitTester = { _, _ in z }
        selection.extend(toWindowPoint: .zero, window: nil)      // a → z: m2 fully selected, unmounted

        let longSource = "A much longer message body that the recycled view now shows instead"
        let long = MarkdownAttributed.rendered(for: longSource, style: .chat)
        view.configure(source: longSource, rendered: long, itemID: "m2", selectionController: selection)
        let textView = try XCTUnwrap(view.textView as? MessageCopyTextView)
        XCTAssertEqual(textView.crossSelectionRange, NSRange(location: 0, length: long.attributed.length))
        XCTAssertNotEqual(long.attributed.length, short.attributed.length)
    }
    // MARK: - Perf follow-ups S4: incremental storage edits while streaming

    /// Streams `source` into a streaming body `step` characters at a time
    /// (plus the whole source last) and checks, after every commit, that the
    /// storage is exactly what a full replace leaves (`StreamingTextEditTests`
    /// explains why that is not `rendered.attributed` itself).
    /// - Returns: per commit, the location its storage write started at
    ///   (0 = full replace) — the commit's LAST edit: the commit where a
    ///   table first appears also processes one for the switch to TextKit 1.
    private func stream(_ source: String, step: Int, into view: MessageBodyView, itemID: String = "eph:r",
                        selectionController: MessageSelectionController? = nil,
                        file: StaticString = #filePath, line: UInt = #line) throws -> [Int] {
        view.isStreaming = true
        let storage = try XCTUnwrap(view.textView.textStorage)
        var locations: [Int] = []
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                              object: storage, queue: nil) { _ in
            locations.append(storage.editedRange.location)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let ends = Array(stride(from: step, to: source.count, by: step)) + [source.count]
        var writes: [Int] = []
        for end in ends {
            let prefix = String(source.prefix(end))
            let rendered = MarkdownAttributed.rendered(for: prefix, style: .chat, cache: false)
            let before = locations.count
            view.configure(source: prefix, rendered: rendered, itemID: itemID, selectionController: selectionController)
            XCTAssertGreaterThan(locations.count, before, "prefix \(end) wrote the storage", file: file, line: line)
            writes.append(locations.last ?? -1)
            XCTAssertTrue(storage.isEqual(to: try fullyReplaced(rendered)), "prefix \(end)", file: file, line: line)
            XCTAssertEqual(storage.string, rendered.attributed.string, "prefix \(end)", file: file, line: line)
        }
        return writes
    }

    /// The storage a non-streaming body holds after a full replace.
    private func fullyReplaced(_ rendered: MarkdownAttributed.Rendered) throws -> NSTextStorage {
        let reference = MessageBodyView()
        reference.configure(source: "", rendered: rendered, itemID: "reference", selectionController: nil)
        return try XCTUnwrap(reference.textView.textStorage)
    }

    func test_streamingFenceOpenedThenClosedEditsIncrementally() throws {
        let source = "Here is the change.\n\n```swift\nfunc apply() {\n    run()\n}\n```\n\nThat is all."
        let locations = try stream(source, step: 1, into: MessageBodyView())
        XCTAssertGreaterThan(locations.filter { $0 > 0 }.count, source.count / 2)
    }

    func test_streamingSetextHeadingEditsIncrementally() throws {
        let source = "Intro paragraph.\n\nA Title\n-------\n\nBody under it."
        let locations = try stream(source, step: 1, into: MessageBodyView())
        XCTAssertGreaterThan(locations.filter { $0 > 0 }.count, source.count / 2)
    }

    func test_streamingTightListTurningLooseEditsIncrementally() throws {
        let source = "Steps:\n\n- one\n- two\n\n- three, now loose\n\nDone."
        let locations = try stream(source, step: 1, into: MessageBodyView())
        XCTAssertGreaterThan(locations.filter { $0 > 0 }.count, source.count / 2)
    }

    /// A table appearing mid-stream: every commit that has one replaces the
    /// whole storage (identity-compared text blocks; the view switches to
    /// TextKit 1), and the commits before it were incremental.
    func test_streamingTableAppearingFallsBackToAFullReplace() throws {
        let intro = "Intro paragraph.\n\nMore text.\n\n"
        let source = intro + "| A | B |\n|---|---|\n| 1 | 2 |"
        let view = MessageBodyView()
        let locations = try stream(source, step: 1, into: view)
        let tabled = (1...source.count).map {
            MarkdownAttributed.rendered(for: String(source.prefix($0)), style: .chat, cache: false).containsTable
        }
        XCTAssertEqual(locations.count, tabled.count)
        let firstTable = try XCTUnwrap(tabled.firstIndex(of: true))
        XCTAssertTrue(locations[firstTable...].allSatisfy { $0 == 0 }, "\(locations[firstTable...])")
        XCTAssertGreaterThan(locations[..<firstTable].filter { $0 > 0 }.count, intro.count / 2)
        XCTAssertNotNil(view.textView.layoutManager, "tabled body runs on TextKit 1")
    }

    /// The flag is the host's: a body not flagged streaming always replaces
    /// the whole storage, and so does a streaming body shown for another item.
    func test_notStreamingOrANewItemReplacesTheWholeStorage() throws {
        let view = MessageBodyView()
        let storage = try XCTUnwrap(view.textView.textStorage)
        var locations: [Int] = []
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                              object: storage, queue: nil) { _ in
            locations.append(storage.editedRange.location)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        func show(_ source: String, _ id: String) {
            view.configure(source: source, rendered: MarkdownAttributed.rendered(for: source, style: .chat, cache: false),
                           itemID: id, selectionController: nil)
        }
        show("One.\n\nTwo", "m1")
        show("One.\n\nTwo three", "m1")
        view.isStreaming = true
        show("One.\n\nTwo three four", "m2")
        show("One.\n\nTwo three four five", "m2")
        XCTAssertEqual(locations, [0, 0, 0, 5])
    }

    /// A live cross-message span over the streaming body survives each
    /// incremental edit and follows its growth: a fully selected middle
    /// message stays fully selected (painted to its new end), and the
    /// controller's recorded span — what it copies once the row unmounts —
    /// covers the new length too.
    func test_liveCrossSelectionSpanSurvivesAndFollowsAStreamingEdit() throws {
        final class Edge: CrossSelectionTarget {
            let selectionItemID: String?
            let frameInWindow: NSRect
            init(_ id: String, y: CGFloat) { selectionItemID = id; frameInWindow = NSRect(x: 0, y: y, width: 100, height: 20) }
            var storageLength: Int { 4 }
            func characterIndex(atWindowPoint point: NSPoint) -> Int { 2 }
            func setCrossSelection(_ range: NSRange?) {}
            func crossSelectionMarkdown() -> String { "" }
        }
        let selection = MessageSelectionController()
        selection.orderedIDs = ["a", "eph:r", "z"]
        let a = Edge("a", y: 200), z = Edge("z", y: 0)
        selection.register(a); selection.register(z)
        var current: (attributed: NSAttributedString, source: String)?
        selection.contentProvider = { id in id == "eph:r" ? current : nil }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let view = MessageBodyView()
        view.frame = NSRect(x: 0, y: 100, width: 400, height: 80)
        window.contentView?.addSubview(view)
        let textView = try XCTUnwrap(view.textView as? MessageCopyTextView)
        view.isStreaming = true
        func show(_ source: String) -> MarkdownAttributed.Rendered {
            let rendered = MarkdownAttributed.rendered(for: source, style: .chat, cache: false)
            current = (rendered.attributed, source)
            view.configure(source: source, rendered: rendered, itemID: "eph:r", selectionController: selection)
            return rendered
        }
        let first = show("First paragraph.\n\nSecond")
        XCTAssertTrue(selection.beginCrossMessage(anchorID: "a", charIndex: 2))
        selection.hitTester = { _, _ in z }
        selection.extend(toWindowPoint: .zero, window: nil)
        XCTAssertEqual(textView.crossSelectionRange, NSRange(location: 0, length: first.attributed.length))

        let storage = try XCTUnwrap(textView.textStorage)
        var locations: [Int] = []
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                              object: storage, queue: nil) { _ in
            locations.append(storage.editedRange.location)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let grownSource = "First paragraph.\n\nSecond one grows"
        let grown = show(grownSource)
        XCTAssertEqual(locations.count, 1)
        XCTAssertGreaterThan(locations.first ?? 0, 0, "the edit was incremental")

        let full = NSRange(location: 0, length: grown.attributed.length)
        XCTAssertEqual(textView.crossSelectionRange, full)
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        let content = try XCTUnwrap(layoutManager.textContentManager)
        let start = content.documentRange.location
        let painted = NSMutableIndexSet()
        layoutManager.enumerateRenderingAttributes(from: start, reverse: false) { _, attributes, range in
            if attributes[.backgroundColor] != nil {
                let lower = content.offset(from: start, to: range.location)
                painted.add(in: NSRange(location: lower, length: content.offset(from: start, to: range.endLocation) - lower))
            }
            return true
        }
        XCTAssertTrue(painted.contains(in: full), "painted \(painted), selected \(full)")
        XCTAssertEqual(selection.selectedSpans().first { $0.id == "eph:r" }?.text, grownSource)

        // Unmounted, the controller copies from its recorded span.
        view.removeFromSuperview()
        XCTAssertEqual(selection.selectedSpans().first { $0.id == "eph:r" }?.text, grownSource)
    }
}
#endif
