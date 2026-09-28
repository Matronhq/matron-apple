import XCTest
import SwiftUI
import MatronChat
import MatronModels
import MatronDesignSystem
@testable import MatronMac

@MainActor final class MacTimelineMeasurerTests: XCTestCase {
    static let corpus = [
        "Hi", "A longer message that will certainly wrap onto a second line at the narrow width we test with here.",
        "# Heading\n\nBody.\n\n- one\n- two", "Before\n\n```swift\nlet x = 1\n```\n\nAfter",
        "| A | B |\n|---|---|\n| 1 | 2 |", "Links: [#65](matron://item/65) and [room](matron://convo/abc-123).",
    ]

    private func item(_ body: String, own: Bool) -> TimelineItem {
        TimelineItem(id: "m-\(body.hashValue)", sender: own ? "@me:s" : "@bot:s", timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                     kind: .text(body: body, formattedHTML: nil), isOwn: own, sendState: .sent)
    }

    /// The SwiftUI row's height at `width` — what the table row must equal.
    private func swiftUIHeight(_ item: TimelineItem, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: MacTimelineItemView(item: item).frame(width: width))
        return host.fittingSize.height
    }

    func test_textRowHeightMatchesSwiftUIRow() {
        for width in [420.0, 700.0, 1100.0] as [CGFloat] {
            for body in Self.corpus {
                for own in [false, true] {
                    let it = item(body, own: own)
                    let content = TextRowContent(itemID: it.id, body: body, isOwn: own, sendState: .sent,
                                                 timestamp: it.timestamp, avatarSender: nil,
                                                 senderLabel: own ? "Me" : "bot",
                                                 pills: ConversationLinkRefs.extract(from: body, cache: true))
                    let measurer = MacTimelineMeasurer(hostedRow: { _ in AnyView(EmptyView()) })
                    let m = measurer.measure(.text(content), width: width)
                    XCTAssertEqual(m.height, swiftUIHeight(it, width: width), accuracy: 1,
                                   "width \(width) own \(own) body \(body.prefix(20))")
                }
            }
        }
    }

    /// Own rows in every non-`.sent` state (the send-state footer) and not-own
    /// rows in a multi-sender room (the avatar column), against the SwiftUI row
    /// built the way `MacTimelineRowView` builds it.
    func test_sendStateAndAvatarRowsMatchSwiftUIRow() {
        let states: [TimelineSendState] = [.sending, .queued, .failed(reason: "boom")]
        var cases: [(TimelineItem, Bool)] = []
        for body in Self.corpus {
            for state in states {
                cases.append((TimelineItem(id: "m-\(body.hashValue)", sender: "@me:s",
                                           timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                           kind: .text(body: body, formattedHTML: nil), isOwn: true,
                                           sendState: state), false))
            }
            cases.append((item(body, own: false), true))
        }
        for width in [420.0, 700.0, 1100.0] as [CGFloat] {
            for (it, multi) in cases {
                guard case .text(let body, _) = it.kind else { continue }
                let content = TextRowContent(itemID: it.id, body: body, isOwn: it.isOwn, sendState: it.sendState,
                                             timestamp: it.timestamp,
                                             avatarSender: TimelineSenderLabels.avatarSender(for: it, hasMultipleSenders: multi),
                                             senderLabel: it.isOwn ? "Me" : "bot",
                                             pills: ConversationLinkRefs.extract(from: body, cache: true))
                let measurer = MacTimelineMeasurer(hostedRow: { _ in AnyView(EmptyView()) })
                let m = measurer.measure(.text(content), width: width)
                let host = NSHostingView(rootView: MacTimelineItemView(item: it, hasMultipleSenders: multi)
                    .frame(width: width))
                let ui = host.fittingSize.height
                XCTAssertEqual(m.height, ui, accuracy: 1,
                               "width \(width) own \(it.isOwn) state \(it.sendState) avatar \(multi) body \(body.prefix(20))")
            }
        }
    }

    /// Spec §6 frame parity: at 420 / 700 / 1100 pt, for the corpus, own and
    /// not-own, with and without the avatar, the table row's bubble frame,
    /// text origin and timestamp match the SwiftUI `MacTimelineItemView` row
    /// within 1 pt.
    ///
    /// Reading SwiftUI's frames: the body is a real `NSTextView`, so its frame
    /// in the host is the text origin. The bubble is a SwiftUI background
    /// with no view of its own: its edges are read off a bitmap of the host
    /// (the run of its fill colour, sampled inside the left padding, through
    /// the padding strips). The timestamp is a SwiftUI `Text` with no view and
    /// — in a test host — no accessibility tree to read a frame from, so it
    /// is compared by INK: the same string in the same font, so the bounding
    /// box of its glyph pixels right of the body, in the SwiftUI row and in a
    /// real `MacTextRowView` laid out from the table's `TextRowLayout`, must
    /// coincide within 1 pt exactly when the two timestamp frames do.
    func test_textRowFramesMatchSwiftUIRow() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        // A plain container: the rows keep their own frames (as the window's
        // content view a row would be stretched to the window and centred).
        let container = FlippedContainer(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
        window.contentView = container
        var cases = 0
        var worst: [String: CGFloat] = [:]
        func check(_ name: String, _ ui: CGFloat, _ table: CGFloat, _ label: String) {
            XCTAssertEqual(ui, table, accuracy: 1, "\(name) — \(label)")
            worst[name] = max(worst[name] ?? 0, abs(ui - table))
        }
        for width in [420.0, 700.0, 1100.0] as [CGFloat] {
            for body in Self.corpus {
                for (own, multi) in [(false, false), (true, false), (false, true)] {
                    let it = item(body, own: own)
                    let content = TextRowContent(itemID: it.id, body: body, isOwn: own, sendState: .sent,
                                                 timestamp: it.timestamp,
                                                 avatarSender: TimelineSenderLabels.avatarSender(for: it, hasMultipleSenders: multi),
                                                 senderLabel: own ? "Me" : "bot",
                                                 pills: ConversationLinkRefs.extract(from: body, cache: true))
                    let measurer = MacTimelineMeasurer(hostedRow: { _ in AnyView(EmptyView()) })
                    guard case .text(let render) = measurer.measure(.text(content), width: width) else {
                        return XCTFail("text row measured as hosted")
                    }
                    let layout = render.layout
                    let tableBubble = layout.bubbleFrame
                    let tableText = layout.segmentFrames[0].offsetBy(dx: tableBubble.minX, dy: tableBubble.minY)
                    let label = "width \(width) own \(own) avatar \(multi) body \(body.prefix(20))"
                    cases += 1

                    let host = NSHostingView(rootView: MacTimelineItemView(item: it, hasMultipleSenders: multi)
                        .frame(width: width))
                    host.appearance = NSAppearance(named: .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
                    let row = MacTextRowView(frame: NSRect(x: 0, y: 0, width: width, height: layout.rowHeight))
                    row.appearance = NSAppearance(named: .aqua)
                    row.configure(render: render, selectionController: nil, linkRouting: .init(),
                                  pills: { nil }, sendState: { nil })
                    container.subviews.forEach { $0.removeFromSuperview() }
                    container.addSubview(host)
                    host.layoutSubtreeIfNeeded()

                    let ui = try XCTUnwrap(SwiftUIRowFrames(host: host), label)
                    check("text x", ui.text.minX, tableText.minX, label)
                    check("text y", ui.text.minY, tableText.minY, label)
                    check("bubble x", ui.bubble.minX, tableBubble.minX, label)
                    check("bubble width", ui.bubble.width, tableBubble.width, label)
                    check("bubble y", ui.bubble.minY, tableBubble.minY, label)
                    check("bubble height", ui.bubble.height, tableBubble.height, label)

                    // Timestamp ink, in the strip right of both bodies.
                    let strip = CGRect(x: max(ui.text.maxX, tableText.maxX) + 1, y: tableBubble.minY,
                                       width: width - max(ui.text.maxX, tableText.maxX) - 1, height: tableBubble.height)
                    let uiInk = try XCTUnwrap(RowBitmap(host).inkBounds(in: strip), "no SwiftUI timestamp ink — \(label)")
                    container.subviews.forEach { $0.removeFromSuperview() }
                    container.addSubview(row)
                    row.layoutSubtreeIfNeeded()
                    let tableInk = try XCTUnwrap(RowBitmap(row).inkBounds(in: strip), "no table timestamp ink — \(label)")
                    // The ink must sit inside the laid-out timestamp frame, or
                    // this compared something else.
                    let tableTime = layout.timestampFrame.offsetBy(dx: tableBubble.minX, dy: tableBubble.minY)
                    XCTAssertTrue(tableTime.insetBy(dx: -1, dy: -1).contains(tableInk), "ink outside the time frame — \(label)")
                    check("time ink minX", uiInk.minX, tableInk.minX, label)
                    check("time ink maxX", uiInk.maxX, tableInk.maxX, label)
                    check("time ink minY", uiInk.minY, tableInk.minY, label)
                    check("time ink maxY", uiInk.maxY, tableInk.maxY, label)
                }
            }
        }
        print("FRAME-PARITY cases=\(cases) worst " + worst.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }

    func test_cacheHitsOnlyForEqualContent() {
        let cache = MacTimelineMeasureCache(countLimit: 10)
        let a = TimelineRowContent.hosted(HostedRowContent(row: .separator(date: Date(timeIntervalSince1970: 0)),
                                                           subtaskChild: nil, hasMultipleSenders: false, imagePixelSize: nil))
        cache.store(.hosted(30), roomID: "r", content: a, width: 500)
        XCTAssertEqual(cache.measurement(roomID: "r", content: a, width: 500)?.height, 30)
        XCTAssertNil(cache.measurement(roomID: "r", content: a, width: 501))
    }
}

/// A SwiftUI `MacTimelineItemView` row's frames, top-left origin in the
/// host (see `test_textRowFramesMatchSwiftUIRow`).
private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

/// A view's pixels (its window's backing scale), addressed in top-left points.
@MainActor private struct RowBitmap {
    let rep: NSBitmapImageRep
    let scale: CGFloat
    let flipped: Bool
    let height: CGFloat

    init(_ view: NSView) {
        rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        scale = CGFloat(rep.pixelsWide) / view.bounds.width
        flipped = view.isFlipped
        height = view.bounds.height
    }

    func px(_ v: CGFloat) -> Int { Int((v * scale).rounded(.down)) }

    func color(_ x: Int, _ y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
        return rep.colorAt(x: x, y: y)
    }

    /// Bounding box (points) of the pixels in `rect` that differ from the
    /// strip's background (its top-left pixel), each composited over white
    /// so a translucent label on a transparent row reads like one on a bubble.
    func inkBounds(in rect: CGRect) -> CGRect? {
        func flat(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat) {
            let a = c.alphaComponent
            return (c.redComponent * a + (1 - a), c.greenComponent * a + (1 - a), c.blueComponent * a + (1 - a))
        }
        let x0 = px(rect.minX), x1 = min(px(rect.maxX), rep.pixelsWide - 1)
        let y0 = px(rect.minY), y1 = min(px(rect.maxY), rep.pixelsHigh - 1)
        guard x1 > x0, y1 > y0, let bgColor = color(x0, y0 + px(4)) else { return nil }
        let bg = flat(bgColor)
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in y0...y1 {
            for x in x0...x1 {
                guard let c = color(x, y) else { continue }
                let f = flat(c)
                guard abs(f.0 - bg.0) + abs(f.1 - bg.1) + abs(f.2 - bg.2) > 0.45 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}

/// A SwiftUI `MacTimelineItemView` row's body and bubble frames, top-left
/// origin in the host (see `test_textRowFramesMatchSwiftUIRow`).
@MainActor private struct SwiftUIRowFrames {
    let text: CGRect
    let bubble: CGRect

    init?(host: NSView) {
        guard let textView = Self.firstTextView(in: host) else { return nil }
        let frame = textView.convert(textView.bounds, to: host)
        text = host.isFlipped ? frame
            : CGRect(x: frame.minX, y: host.bounds.height - frame.maxY, width: frame.width, height: frame.height)

        let bitmap = RowBitmap(host)
        // Inside the left padding strip (8 pt in from the edge, past the
        // 8 pt corner), 2 pt below the text's top.
        let probeX = bitmap.px(text.minX - 4), probeY = bitmap.px(text.minY + 2)
        guard let fill = bitmap.color(probeX, probeY) else { return nil }
        // Edge pixels are the fill antialiased over the shadow (nearly
        // opaque, slightly darker); outside is the shadow (low alpha) or
        // nothing — so the match is loose on colour, tight on alpha.
        func isFill(_ x: Int, _ y: Int) -> Bool {
            guard let c = bitmap.color(x, y) else { return false }
            return abs(c.redComponent - fill.redComponent) < 0.12 && abs(c.greenComponent - fill.greenComponent) < 0.12
                && abs(c.blueComponent - fill.blueComponent) < 0.12 && c.alphaComponent > 0.9
        }
        var left = probeX
        while isFill(left - 1, probeY) { left -= 1 }
        // The right edge: the last fill pixel on the row — nothing but the
        // bubble carries its fill right of the body (pills sit below).
        var right = bitmap.rep.pixelsWide - 1
        while right > probeX, !isFill(right, probeY) { right -= 1 }
        var top = probeY, bottom = probeY
        while isFill(probeX, top - 1) { top -= 1 }
        while isFill(probeX, bottom + 1) { bottom += 1 }
        let scale = bitmap.scale
        bubble = CGRect(x: CGFloat(left) / scale, y: CGFloat(top) / scale,
                        width: CGFloat(right - left + 1) / scale, height: CGFloat(bottom - top + 1) / scale)
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }
}
