#if os(macOS)
import XCTest
import AppKit
@testable import MatronDesignSystem

/// A table body is drawn by TextKit 1, which left to itself lays the text
/// out at whatever size the text view has and resizes the view to fit,
/// a few lines at a time in the background. A host that recycles bodies
/// (the item thread, the chat timeline) hands a view that last showed a
/// short reply at another width a table at a new frame: TextKit laid the
/// table out at the old width, grew the text view past its host, drew it,
/// then shrank it back while filling the rest in later. Rows drawn in
/// between came out clipped, with a gap below, until the next full redraw.
/// The host's frame is the only size the text view may have.
@MainActor
final class MessageBodyViewTableGeometryTests: XCTestCase {
    private static let table = """
    | Change | What it does | Who notices | Risk |
    |---|---|---|---|
    | First | Orders keep their delivery address when the account that placed them is merged into another one. | Nobody: the address was already on the order. | normal |
    | Second | A new account made from an invite gets a welcome about the order instead of the general welcome, and the rest of the team gets a short notice. | One new email, and a notice that is never emailed. | normal |
    | Third | Saved designs keep their text-line markers, so files made straight from them print each line in its own colour. | Nothing on screen. Print files were already right. | normal |
    | Fourth | Picking a two-tone colour on a product card recolours the live preview. | The preview shows the contrasting hood. | normal |
    """

    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func mountedBody() -> (MessageBodyView, NSView) {
        let root = FlippedHost(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = root
        self.window = window
        let body = MessageBodyView()
        body.forcesTextKit1 = true
        root.addSubview(body)
        return (body, root)
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Every size the text view takes from now on.
    private func recordSizes(of view: NSView) -> (sizes: () -> [CGSize], stop: () -> Void) {
        var sizes: [CGSize] = []
        view.postsFrameChangedNotifications = true
        let token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view,
                                                           queue: nil) { note in
            MainActor.assumeIsolated { sizes.append((note.object as! NSView).frame.size) }
        }
        return ({ sizes }, { NotificationCenter.default.removeObserver(token) })
    }

    func test_recycledBody_givenATable_onlyEverTakesItsHostsFrame() {
        for oldWidth: CGFloat in [72, 300, 424] {
            let (body, _) = mountedBody()
            let reply = "A short reply about the table."
            let replyRendered = MarkdownAttributed.rendered(for: reply, style: .item, cache: false)
            body.frame = CGRect(x: 0, y: 0, width: oldWidth, height: ceil(replyRendered.size(width: oldWidth).height))
            body.configure(source: reply, rendered: replyRendered, itemID: "reply", selectionController: nil)
            window?.displayIfNeeded()
            spin(0.1)

            let rendered = MarkdownAttributed.rendered(for: Self.table, style: .item, cache: false)
            let size = rendered.size(width: 612)
            let host = CGSize(width: 612, height: ceil(size.height))
            let recorder = recordSizes(of: body.textView)
            // As the item thread's card cell does: the frame, then the content.
            body.frame = CGRect(origin: .zero, size: host)
            body.configure(source: Self.table, rendered: rendered, itemID: "table", selectionController: nil)
            window?.displayIfNeeded()
            spin()
            recorder.stop()

            let strays = recorder.sizes().filter { $0 != host }
            XCTAssertEqual(strays, [], "from a body \(oldWidth) wide, the text view took sizes other than its host's \(host)")
            XCTAssertEqual(body.textView.frame.size, host)
        }
    }

    /// The same for a width change alone: the text view follows its host
    /// at once, not after TextKit has laid the table out at the old width.
    func test_tableBody_followsAWidthChangeAtOnce() {
        let (body, _) = mountedBody()
        let rendered = MarkdownAttributed.rendered(for: Self.table, style: .item, cache: false)
        body.frame = CGRect(x: 0, y: 0, width: 612, height: ceil(rendered.size(width: 612).height))
        body.configure(source: Self.table, rendered: rendered, itemID: "table", selectionController: nil)
        window?.displayIfNeeded()
        spin(0.1)

        let host = CGSize(width: 480, height: ceil(rendered.size(width: 480).height))
        let recorder = recordSizes(of: body.textView)
        body.frame.size = host
        XCTAssertEqual(body.textView.frame.size, host, "the text view waited for a layout pass")
        window?.displayIfNeeded()
        spin()
        recorder.stop()
        XCTAssertEqual(recorder.sizes().filter { $0 != host }, [])
    }

    /// TextKit 1 neither resizes the view nor lays out in the background:
    /// the host measured the text with the same engine and sized the view.
    func test_textKit1Body_isSizedByItsHostOnly() {
        let (body, _) = mountedBody()
        let rendered = MarkdownAttributed.rendered(for: Self.table, style: .item, cache: false)
        body.frame = CGRect(x: 0, y: 0, width: 612, height: ceil(rendered.size(width: 612).height))
        body.configure(source: Self.table, rendered: rendered, itemID: "table", selectionController: nil)
        XCTAssertFalse(body.textView.isVerticallyResizable)
        XCTAssertEqual(body.textView.layoutManager?.backgroundLayoutEnabled, false)
    }
}

private final class FlippedHost: NSView {
    override var isFlipped: Bool { true }
}
#endif
