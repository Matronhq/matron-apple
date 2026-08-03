#if os(macOS)
import AppKit
import XCTest
@testable import MatronDesignSystem

/// Pins the swallowed-link-click fallback (Dan, 2026-08-03: "often when
/// you click on links nothing happens"). A press that begins on a link and
/// ends as a clean click must open the link even when AppKit's internal
/// press handling aborts without dispatching it.
///
/// The guard logic is driven through `armLinkPress`/`resolveLinkPressIfNeeded`
/// directly: a full headless `mouseDown` flips between AppKit's press
/// paths run to run (inactive-app press semantics), so the deterministic
/// seam is the same one the watchdog tests use — our logic, real hit
/// tests, no nested tracking loop. One integration test at the bottom
/// drives real `mouseDown`/`mouseUp` and pins the invariant that holds in
/// EVERY environment: exactly one dispatch, never two.
@MainActor
final class LinkClickTrackingTests: XCTestCase {

    private final class LinkRecorder: NSObject, NSTextViewDelegate {
        var clicked: [URL] = []
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            (textView as? MouseTrackingRescueTextView)?.noteLinkClickHandled()
            if let url = link as? URL { clicked.append(url) }
            return true
        }
    }

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private static let linkURL = URL(string: "matron-test://link-click")!
    private static let bodyFont = NSFont.systemFont(ofSize: 13)

    private var window: NSWindow!
    private var textView: MouseTrackingRescueTextView!
    private var recorder: LinkRecorder!

    override func setUp() {
        super.setUp()
        recorder = LinkRecorder()
        textView = MouseTrackingRescueTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = recorder
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textStorage?.setAttributedString(Self.makeAttributed())
        // Pointer stays put by default — each press reads as a clean click.
        textView.currentScreenLocation = { NSPoint(x: 100, y: 100) }

        window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
    }

    override func tearDown() {
        window.orderOut(nil)
        window = nil
        textView = nil
        recorder = nil
        super.tearDown()
    }

    /// "click thelink after…" with `.link` on the middle word — built by
    /// hand, not via markdown, so this suite pins the press machinery
    /// rather than the converter (MarkdownAttributedTests own that seam).
    private static func makeAttributed(suffix: String = "") -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor,
        ]
        out.append(NSAttributedString(string: "click ", attributes: base))
        out.append(NSAttributedString(string: "thelink", attributes: [
            .font: bodyFont,
            .link: linkURL,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
        out.append(NSAttributedString(string: " after\(suffix)", attributes: base))
        return out
    }

    /// A window-coordinate point over the middle of the given substring,
    /// measured from character advances — the whole line is one 13pt
    /// system-font size, so the midpoint is safely inside.
    private func windowPoint(over substring: String = "thelink") -> NSPoint {
        let full = textView.textStorage!.string as NSString
        let range = full.range(of: substring)
        let prefixWidth = full.substring(to: range.location)
            .size(withAttributes: [.font: Self.bodyFont]).width
        let width = full.substring(with: range)
            .size(withAttributes: [.font: Self.bodyFont]).width
        return textView.convert(NSPoint(x: prefixWidth + width / 2, y: 8), to: nil)
    }

    private func down(
        at p: NSPoint, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: p, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 4242, clickCount: clickCount, pressure: 1
        )!
    }

    // MARK: - The swallowed click heals

    func test_swallowedLinkClick_isDispatchedExactlyOnce() {
        textView.armLinkPress(for: down(at: windowPoint()))
        textView.resolveLinkPressIfNeeded()
        XCTAssertEqual(recorder.clicked, [Self.linkURL],
                       "a clean click AppKit dropped must be dispatched")
        textView.resolveLinkPressIfNeeded()
        XCTAssertEqual(recorder.clicked, [Self.linkURL],
                       "the press is consumed — a second resolve must not re-dispatch")
    }

    func test_storageReplacedMidPress_stillOpensLink() {
        // A streaming delta re-sets the text storage of a visible message
        // (`updateNSView`) — the press must still open the pressed link.
        textView.armLinkPress(for: down(at: windowPoint()))
        textView.textStorage?.setAttributedString(Self.makeAttributed(suffix: " and more streamed text"))
        textView.resolveLinkPressIfNeeded()
        XCTAssertEqual(recorder.clicked, [Self.linkURL])
    }

    func test_storageShrunkBelowPressIndex_opensLinkWithoutCrashing() {
        textView.armLinkPress(for: down(at: windowPoint()))
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: "x", attributes: [.font: Self.bodyFont]))
        textView.resolveLinkPressIfNeeded()
        XCTAssertEqual(recorder.clicked, [Self.linkURL],
                       "the char index must clamp to the shrunken storage; the link value survives")
    }

    // MARK: - The fallback never double-dispatches

    func test_appKitHandledClick_isNotDispatchedAgain() {
        textView.armLinkPress(for: down(at: windowPoint()))
        // AppKit's own dispatch route — consults the delegate itself.
        textView.clicked(onLink: Self.linkURL, at: 8)
        textView.resolveLinkPressIfNeeded()
        XCTAssertEqual(recorder.clicked, [Self.linkURL],
                       "when AppKit dispatches the link itself the fallback must stay silent")
    }

    func test_delegateOnlyHandling_isNotDispatchedAgain() {
        // Some AppKit routes reach the delegate without `clicked(onLink:at:)`
        // — `noteLinkClickHandled()` alone must suppress the fallback.
        textView.armLinkPress(for: down(at: windowPoint()))
        textView.noteLinkClickHandled()
        textView.resolveLinkPressIfNeeded()
        XCTAssertTrue(recorder.clicked.isEmpty)
    }

    // MARK: - Only clean clicks on links qualify

    func test_dragOffTheLink_doesNotDispatch() {
        var reads = 0
        textView.currentScreenLocation = {
            defer { reads += 1 }
            return reads == 0 ? NSPoint(x: 100, y: 100) : NSPoint(x: 160, y: 90)
        }
        textView.armLinkPress(for: down(at: windowPoint()))
        textView.resolveLinkPressIfNeeded()
        XCTAssertTrue(recorder.clicked.isEmpty,
                      "a press that travelled is a drag, not a click")
    }

    func test_selectionCreatedDuringPress_doesNotDispatch() {
        textView.armLinkPress(for: down(at: windowPoint()))
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        textView.resolveLinkPressIfNeeded()
        XCTAssertTrue(recorder.clicked.isEmpty,
                      "a press that selected text was a selection gesture")
    }

    func test_pressOffTheLink_doesNotArm() {
        textView.armLinkPress(for: down(at: windowPoint(over: "after")))
        textView.resolveLinkPressIfNeeded()
        XCTAssertTrue(recorder.clicked.isEmpty)
    }

    func test_doubleClick_doesNotArm() {
        textView.armLinkPress(for: down(at: windowPoint(), clickCount: 2))
        textView.resolveLinkPressIfNeeded()
        XCTAssertTrue(recorder.clicked.isEmpty,
                      "double-clicks select the word; they never open links")
    }

    func test_modifiedClick_doesNotArm() {
        textView.armLinkPress(for: down(at: windowPoint(), modifiers: [.command]))
        textView.resolveLinkPressIfNeeded()
        XCTAssertTrue(recorder.clicked.isEmpty,
                      "modifier clicks keep AppKit's own semantics untouched")
    }

    func test_editableTextView_doesNotArm() {
        // The composer subclass is editable — plain clicks place the caret
        // there and must never grow link-opening behaviour.
        textView.isEditable = true
        textView.armLinkPress(for: down(at: windowPoint()))
        textView.resolveLinkPressIfNeeded()
        XCTAssertTrue(recorder.clicked.isEmpty)
    }

    // MARK: - Full-press integration invariant

    func test_fullPress_dispatchesExactlyOnce_regardlessOfPath() {
        // Whichever press path this environment's AppKit takes (drop the
        // click → fallback dispatches; complete the click → AppKit
        // dispatches and the fallback stays silent), the user-visible
        // outcome must be identical: the link opens exactly once.
        let p = windowPoint()
        var released = false
        let began = Date()
        // Hang guard: if AppKit enters its nested tracking loop, the 1s cap
        // flips the seam so the rescue watchdog can end the press.
        textView.leftButtonIsDown = { !released && Date().timeIntervalSince(began) < 1.0 }
        textView.mouseDown(with: down(at: p))
        released = true
        textView.mouseUp(with: NSEvent.mouseEvent(
            with: .leftMouseUp, location: p, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 4242, clickCount: 1, pressure: 0
        )!)
        XCTAssertEqual(recorder.clicked, [Self.linkURL],
                       "one press on a link = the link opens exactly once, never zero, never twice")
    }
}
#endif
