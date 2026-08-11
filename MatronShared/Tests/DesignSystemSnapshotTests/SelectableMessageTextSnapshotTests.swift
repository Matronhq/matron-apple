#if os(macOS)
import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

/// Visual-regression baseline for the Mac selectable message body. Renders a
/// message exercising the block kinds the converter maps (paragraphs, an
/// unordered list, inline formatting, and a fenced code block) so a regression
/// in `MarkdownAttributed` or the `NSTextView` layout is caught here.
final class SelectableMessageTextSnapshotTests: XCTestCase {
    func test_richMessage() {
        let view = SelectableMessageText("""
        Here's a **rich** message with some *emphasis* and `inline code`.

        A short list:
        - First item
        - Second item

        And a fenced block:
        ```swift
        let greeting = "hello"
        ```
        """)
        .frame(width: 320)
        .padding()
        assertVariants(of: view, named: "richMessage")
    }

    func test_tableMessage() {
        let view = SelectableMessageText("""
        Release status:

        | Repo | PR | State |
        | :--- | :---: | ---: |
        | bridge | [#215](https://example.com) | **merged** |
        | apple | #133 | open |

        Merge order doesn't matter.
        """)
        .frame(width: 420)
        .padding()
        assertVariants(of: view, named: "tableMessage")
    }

    /// Regression under test (Dan, 2026-07-16): long plan-style messages with
    /// markdown headings rendered with a big dead band at the BOTTOM of the
    /// bubble. The bubble height comes from `MarkdownAttributed.size` — a
    /// TextKit 1 measurement — but a plain `NSTextView()` renders with
    /// TextKit 2 on modern macOS, and the two engines disagree (spacing and
    /// line rounding) by an amount that grows with the number of blocks.
    /// The view must render its text at the exact height the measurement
    /// promised, whichever engine it uses.
    @MainActor
    func test_liveTextView_rendersAtMeasuredHeight_forHeadingHeavyDocument() {
        // Plan-shaped body: repeated heading + paragraph + list sections, the
        // shape Dan reported. Enough blocks that a per-block divergence
        // accumulates well past the tolerance.
        let section = """
        ## Phase heading

        A paragraph explaining the phase in enough words that it wraps onto \
        several lines at the fixture width, like a real plan message does.

        - first step of the phase
        - second step of the phase

        """
        let source = String(repeating: section, count: 8)
        let width: CGFloat = 480

        let attributed = MarkdownAttributed.attributedString(for: source)
        let measured = MarkdownAttributed.size(for: attributed, source: source, width: width)

        // Host the real view at exactly the size the measurement reported —
        // the same thing the timeline does with `sizeThatFits`'s answer.
        let host = NSHostingView(
            rootView: SelectableMessageText(source)
                .frame(width: measured.width, height: measured.height)
        )
        host.frame = NSRect(origin: .zero, size: NSSize(width: measured.width, height: measured.height))
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        defer { window.orderOut(nil) }

        guard let textView = firstTextView(in: host) else {
            return XCTFail("no NSTextView in SelectableMessageText hierarchy")
        }
        let rendered = renderedTextHeight(of: textView)

        XCTAssertEqual(
            rendered, measured.height, accuracy: 2,
            "the live text view must fill the measured height — a shortfall is dead space at the bubble bottom (measured: \(measured.height), rendered: \(rendered))"
        )
    }

    /// A table-bearing message must be on TextKit 1 from the first layout, and
    /// the text view must still sit exactly where SwiftUI placed it. TextKit 2
    /// can't lay out `NSTextTable`, and AppKit's own fallback only fires once
    /// the view is in a window — the re-size that follows keeps the view's TOP
    /// edge, so its origin walks off the frame and the first rows are clipped
    /// (origin.y was 64 in a 131pt frame before the fix).
    @MainActor
    func test_tableMessage_usesTextKit1AndKeepsItsFrame() {
        let source = """
        | Repo | PR |
        | :--- | ---: |
        | bridge | 215 |
        | apple | 133 |
        """
        let attributed = MarkdownAttributed.attributedString(for: source)
        let measured = MarkdownAttributed.size(for: attributed, source: source, width: 420)

        let host = NSHostingView(
            rootView: SelectableMessageText(source)
                .frame(width: measured.width, height: measured.height)
        )
        host.frame = NSRect(origin: .zero, size: measured)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        defer { window.orderOut(nil) }

        guard let textView = firstTextView(in: host) else {
            return XCTFail("no NSTextView in SelectableMessageText hierarchy")
        }
        XCTAssertNil(textView.textLayoutManager, "table messages must render through TextKit 1")
        XCTAssertEqual(textView.frame.origin.y, 0, accuracy: 0.5,
                       "text view moved off its frame: \(textView.frame) in \(host.frame)")
        XCTAssertEqual(renderedTextHeight(of: textView), measured.height, accuracy: 2)
    }

    /// Laid-out text height through whichever TextKit engine the view is
    /// actually using — asking `layoutManager` first would silently convert a
    /// TextKit 2 view to TextKit 1 and mask the mismatch under test.
    @MainActor
    private func renderedTextHeight(of textView: NSTextView) -> CGFloat {
        if let textLayoutManager = textView.textLayoutManager {
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
            return textLayoutManager.usageBoundsForTextContainer.height
        }
        guard let lm = textView.layoutManager, let tc = textView.textContainer else {
            return textView.frame.height
        }
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc).height
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for sub in view.subviews {
            if let found = firstTextView(in: sub) { return found }
        }
        return nil
    }
}
#endif
