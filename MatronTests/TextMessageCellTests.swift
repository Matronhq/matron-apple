import XCTest
import SwiftUI
import UIKit
import MatronModels
import MatronDesignSystem
@testable import Matron

@MainActor
final class TextMessageCellTests: XCTestCase {
    private let style = TimelineTextStyle(sizeCategory: .large)

    private func factory() -> HostedRowFactory {
        HostedRowFactory(viewModel: TimelineFixtures.viewModel(LiveTimelineFixture()), actions: .inert,
                         environment: TimelineHostedEnvironment())
    }

    private func content(_ body: String, own: Bool = false, state: TimelineSendState = .sent,
                         avatar: String? = nil, pills: [ConversationLinkRef] = []) -> TextRowContent {
        TextRowContent(itemID: "1", body: body, isOwn: own, sendState: state, timestamp: TimelineFixtures.base,
                       avatarSender: avatar, senderLabel: own ? "Me" : (avatar ?? "matron"), pills: pills)
    }

    /// Kept alive for the life of the test: `UIHostingConfiguration`'s
    /// content view (the `.table` segment, the pills row) never installs
    /// its SwiftUI child at all off-window (confirmed empirically — zero
    /// subviews). Production cells never hit this — a `UICollectionView`
    /// only configures a cell once it's already part of the window-attached
    /// collection view — so windowing here matches production, rather than
    /// working around a test-only gap.
    private var windowsKeepingCellsRendering: [UIWindow] = []

    /// A window-attached cell's rendered pixels, for A/B comparisons (e.g.
    /// "does a safe-area inset change what the hosted content draws")
    /// without a golden-file snapshot for every variant.
    private func renderedPNG(_ view: UIView) -> Data? {
        UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }.pngData()
    }

    private func cell(_ content: TextRowContent, width: CGFloat = 393) -> TextMessageCell {
        let factory = factory()
        guard case .text(let render) = TimelineMeasurer(factory: factory).measure(.text(content), width: width,
                                                                                  style: style) else {
            fatalError("text rows measure as renders")
        }
        let cell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: render.layout.rowHeight))
        let window = UIWindow(frame: cell.frame)
        window.isHidden = false
        window.addSubview(cell)
        windowsKeepingCellsRendering.append(window)
        cell.configure(render: render, factory: factory, onRetry: { _ in })
        cell.layoutIfNeeded()
        return cell
    }

    func test_configure_buildsOneViewPerSegment_inTheLayoutFrames() {
        let cell = cell(content("Intro.\n\n```swift\nlet x = 1\n```\n\nOutro."))
        XCTAssertEqual(cell.segmentViewsForTesting.count, 3)
        XCTAssertTrue(cell.segmentViewsForTesting[0] is UITextView)
        XCTAssertTrue(cell.segmentViewsForTesting[1] is CodeBlockSegmentView)
        XCTAssertEqual(cell.segmentViewsForTesting.map(\.frame), cell.render?.layout.segmentFrames)
        XCTAssertEqual(cell.bubbleForTesting.frame, cell.render?.layout.bubbleFrame)
    }

    func test_reconfigure_reusesSegmentViews_whenTheKindsMatch() {
        let cell = cell(content("first body"))
        let before = cell.segmentViewsForTesting.map(ObjectIdentifier.init)
        let factory = factory()
        guard case .text(let render) = TimelineMeasurer(factory: factory).measure(
            .text(content("second, longer body that wraps")), width: 393, style: style) else { return XCTFail() }
        cell.configure(render: render, factory: factory, onRetry: { _ in })
        XCTAssertEqual(cell.segmentViewsForTesting.map(ObjectIdentifier.init), before,
                       "the streaming row reconfigures in place — no view churn per frame")
        XCTAssertEqual((cell.segmentViewsForTesting[0] as? UITextView)?.text, "second, longer body that wraps")
    }

    /// Task 29 perf gate: a recycled cell whose next row has a different
    /// segment shape takes the views it already owns — creating TextKit
    /// text views on the scroll path was the top cost of a fast fling.
    func test_reconfigure_toADifferentShape_reusesViewsItAlreadyOwns() {
        let cell = cell(content("Intro.\n\n```swift\nlet x = 1\n```\n\nOutro."))
        let owned = Set(cell.segmentViewsForTesting.map(ObjectIdentifier.init))
        let factory = factory()
        func configure(_ body: String) {
            guard case .text(let render) = TimelineMeasurer(factory: factory).measure(
                .text(content(body)), width: 393, style: style) else { return XCTFail() }
            cell.configure(render: render, factory: factory, onRetry: { _ in })
            cell.layoutIfNeeded()
        }

        configure("just prose")
        XCTAssertEqual(cell.segmentViewsForTesting.count, 1)
        XCTAssertTrue(owned.contains(ObjectIdentifier(cell.segmentViewsForTesting[0])))
        let spares = cell.bubbleForTesting.subviews.filter { view in
            owned.contains(ObjectIdentifier(view)) && !cell.segmentViewsForTesting.contains(view)
        }
        XCTAssertEqual(spares.count, 2)
        XCTAssertTrue(spares.allSatisfy(\.isHidden), "unused segment views stay as hidden spares")
        XCTAssertFalse(cell.segmentViewsForTesting[0].isHidden)
        XCTAssertEqual((cell.segmentViewsForTesting[0] as? UITextView)?.text, "just prose")

        configure("Again.\n\n```swift\nlet y = 2\n```\n\nDone.")
        XCTAssertEqual(Set(cell.segmentViewsForTesting.map(ObjectIdentifier.init)), owned,
                       "the original shape comes back from the cell's own views — none created")
        XCTAssertTrue(cell.segmentViewsForTesting[1] is CodeBlockSegmentView)
        XCTAssertFalse(cell.segmentViewsForTesting.contains(where: \.isHidden))
        XCTAssertEqual(cell.segmentViewsForTesting.map(\.frame), cell.render?.layout.segmentFrames)
        XCTAssertEqual((cell.segmentViewsForTesting[2] as? UITextView)?.text, "Done.")
    }

    func test_ownSendingRow_dimsTheBubble_andShowsTheSendState() {
        let cell = cell(content("On my way", own: true, state: .sending))
        // `UIView.alpha` bridges to `CALayer.opacity` (`Float`, 32-bit), so
        // an exact `Double` literal doesn't round-trip — `accuracy:` checks
        // the same 70% the assignment intends.
        XCTAssertEqual(cell.bubbleForTesting.alpha, 0.7, accuracy: 0.001)
        XCTAssertFalse(cell.sendStateForTesting.isHidden)
        XCTAssertEqual(cell.sendStateForTesting.frame, cell.render?.layout.sendStateFrame)
    }

    func test_linkDecision_systemLinksUseUIKitsDefault() {
        XCTAssertEqual(TextMessageCell.linkDecision(for: URL(string: "https://example.com")!), .system)
        XCTAssertEqual(TextMessageCell.linkDecision(for: URL(string: "matron://item/5")!), .inApp)
        XCTAssertEqual(TextMessageCell.linkDecision(for: URL(string: "matron://convo/c-1")!), .inApp)
        XCTAssertEqual(TextMessageCell.linkDecision(for: URL(string: "matrix:r/x:s")!), .inApp,
                       "swallowed links route through the router, which consumes them")
    }

    func test_textView_isLabelledWithTheSender() {
        XCTAssertEqual((cell(content("hi", own: true)).segmentViewsForTesting[0] as? UITextView)?.accessibilityLabel, "Me")
        XCTAssertEqual((cell(content("hi", avatar: "dev-2")).segmentViewsForTesting[0] as? UITextView)?.accessibilityLabel,
                       "dev-2")
    }

    func test_palette_matchesTheSwiftUIColors() {
        func rgba(_ color: UIColor) -> [CGFloat] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b, a]
        }
        for (uiColor, color) in [(UIColor.matronBubbleMe, Color.matronBubbleMe), (.matronBubbleBot, .matronBubbleBot)] {
            for appearance in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: appearance)
                let lhs = rgba(uiColor.resolvedColor(with: traits))
                let rhs = rgba(UIColor(color).resolvedColor(with: traits))
                for (a, b) in zip(lhs, rhs) { XCTAssertEqual(a, b, accuracy: 0.002) }
            }
        }
    }

    func test_snapshots() {
        let cases: [(String, TextRowContent)] = [
            ("bot-plain", content("Found it. The mock server binds a fixed port, so parallel runs race for it.")),
            ("own", content("Can you take a look at the flaky upload test?", own: true)),
            ("avatar", content("Nightly run finished: one flaky failure.", avatar: "dev-2")),
            ("code", content("Run:\n\n```sh\nswift test --filter UploadQueueTests\n```")),
            ("table", content("| Case | Result |\n|:--|--:|\n| retry | ok |\n| timeout | **failed** |")),
            ("pills", content("See [Auth refactor](matron://convo/auth-1).",
                              pills: [ConversationLinkRef(id: "auth-1", text: "Auth refactor")])),
            ("failed", content("This one failed", own: true, state: .failed(reason: "offline"))),
        ]
        for (name, content) in cases {
            let cell = cell(content)
            assertTimelineSnapshot(cell, size: cell.bounds.size, named: "text-cell-\(name)")
        }
    }

    /// A pills row spans the full row width along the row's bottom edge —
    /// exactly where a home indicator or landscape notch inset lives.
    /// Regression guard for `UIHostingConfiguration` leaking that inset
    /// into the hosted content's own layout (it doesn't: confirmed both
    /// here and, at review time, with an exaggerated 200pt inset that made
    /// any leak obvious in a recorded snapshot).
    func test_pillsHostedContent_ignoresTheWindowsSafeArea() {
        let pillsContent = content("See [Auth refactor](matron://convo/auth-1).",
                                   pills: [ConversationLinkRef(id: "auth-1", text: "Auth refactor")])
        let plain = cell(pillsContent)

        let factory = factory()
        guard case .text(let render) = TimelineMeasurer(factory: factory).measure(
            .text(pillsContent), width: 393, style: style) else { return XCTFail() }
        let insetCell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: 393, height: render.layout.rowHeight))
        let rootViewController = UIViewController()
        rootViewController.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 200, right: 0)
        rootViewController.view.frame = insetCell.frame
        rootViewController.view.addSubview(insetCell)
        let window = UIWindow(frame: insetCell.frame)
        window.rootViewController = rootViewController
        window.isHidden = false
        windowsKeepingCellsRendering.append(window)
        insetCell.configure(render: render, factory: factory, onRetry: { _ in })
        insetCell.layoutIfNeeded()

        XCTAssertEqual(renderedPNG(plain), renderedPNG(insetCell),
                       "a bottom safe area must not shift or clip the hosted pill row")
    }

    // MARK: SCRATCH diagnostics

    private func pixels(_ view: UIView) -> (w: Int, h: Int, data: [UInt8]) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let cg = image.cgImage!
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, data)
    }

    private func describe(_ name: String, _ view: UIView) {
        let t = view.traitCollection
        print("PILLDIAG \(name): bounds=\(view.bounds) safeArea=\(view.safeAreaInsets) scale=\(t.displayScale) style=\(t.userInterfaceStyle.rawValue) sizeCat=\(t.preferredContentSizeCategory.rawValue) windowScene=\(view.window?.windowScene != nil) windowKey=\(view.window?.isKeyWindow ?? false) windowSafe=\(view.window?.safeAreaInsets ?? .zero)")
        func dump(_ v: UIView, _ depth: Int) {
            if depth > 6 { return }
            print("PILLDIAG \(name) " + String(repeating: "  ", count: depth) + "\(type(of: v)) frame=\(v.frame) safe=\(v.safeAreaInsets)")
            v.subviews.forEach { dump($0, depth + 1) }
        }
        dump(view, 0)
    }

    private func diff(_ label: String, _ a: UIView, _ b: UIView) {
        let pa = pixels(a), pb = pixels(b)
        guard pa.w == pb.w, pa.h == pb.h else {
            print("PILLDIAG \(label): sizes differ \(pa.w)x\(pa.h) vs \(pb.w)x\(pb.h)")
            return
        }
        var count = 0, minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var samples: [String] = []
        for y in 0..<pa.h {
            for x in 0..<pa.w {
                let i = (y * pa.w + x) * 4
                if pa.data[i] != pb.data[i] || pa.data[i + 1] != pb.data[i + 1]
                    || pa.data[i + 2] != pb.data[i + 2] || pa.data[i + 3] != pb.data[i + 3] {
                    count += 1
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    if samples.count < 12 {
                        samples.append("(\(x),\(y)) \(pa.data[i]),\(pa.data[i + 1]),\(pa.data[i + 2]),\(pa.data[i + 3]) vs \(pb.data[i]),\(pb.data[i + 1]),\(pb.data[i + 2]),\(pb.data[i + 3])")
                    }
                }
            }
        }
        print("PILLDIAG \(label): \(pa.w)x\(pa.h) differing pixels=\(count) box=(\(minX),\(minY))-(\(maxX),\(maxY)) png=\(renderedPNG(a)?.count ?? -1) vs \(renderedPNG(b)?.count ?? -1)")
        samples.forEach { print("PILLDIAG \(label) sample \($0)") }
    }

    private func insetCell(_ pillsContent: TextRowContent, bottom: CGFloat) -> TextMessageCell {
        let factory = factory()
        guard case .text(let render) = TimelineMeasurer(factory: factory).measure(
            .text(pillsContent), width: 393, style: style) else { fatalError() }
        let insetCell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: 393, height: render.layout.rowHeight))
        let rootViewController = UIViewController()
        rootViewController.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
        rootViewController.view.frame = insetCell.frame
        rootViewController.view.addSubview(insetCell)
        let window = UIWindow(frame: insetCell.frame)
        window.rootViewController = rootViewController
        window.isHidden = false
        windowsKeepingCellsRendering.append(window)
        insetCell.configure(render: render, factory: factory, onRetry: { _ in })
        insetCell.layoutIfNeeded()
        return insetCell
    }

    func test_SCRATCH_pillRenderDiff() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for w in scene.windows {
                print("PILLDIAG scene window \(type(of: w)) hidden=\(w.isHidden) key=\(w.isKeyWindow) level=\(w.windowLevel.rawValue) root=\(w.rootViewController.map { String(describing: type(of: $0)) } ?? "nil") frame=\(w.frame)")
            }
        }
        let pillsContent = content("See [Auth refactor](matron://convo/auth-1).",
                                   pills: [ConversationLinkRef(id: "auth-1", text: "Auth refactor")])
        let plainA = cell(pillsContent)
        let plainB = cell(pillsContent)
        let inset200 = insetCell(pillsContent, bottom: 200)
        let inset0 = insetCell(pillsContent, bottom: 0)
        describe("plainA", plainA)
        describe("inset200", inset200)
        describe("inset0", inset0)
        diff("plainA-vs-plainB", plainA, plainB)
        diff("plainA-vs-inset200", plainA, inset200)
        diff("plainA-vs-inset0", plainA, inset0)
        diff("inset0-vs-inset200", inset0, inset200)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        diff("after-1s plainA-vs-inset200", plainA, inset200)
        diff("after-1s plainA-vs-plainB", plainA, plainB)
    }

    /// A Dynamic Type change re-measures and `reconfigureItems`s every row
    /// (never `prepareForReuse`), so the exact same `MarkdownTable` value
    /// can legitimately need re-rendering at a new size. Builds two
    /// `TextRowRender`s directly with an IDENTICAL `MarkdownTable` value
    /// (not routed through the real markdown pipeline, whose fonts are
    /// baked into each cell's `NSAttributedString` and so already differ
    /// per size category — that would make the table value itself unequal
    /// and mask exactly the bug this guards) but different
    /// `style.sizeCategory`, so only the size-category half of the skip's
    /// key is exercised.
    func test_tableHostedContent_reappliesOnSizeCategoryChange_withoutPrepareForReuse() {
        let table = MarkdownTable(columnCount: 2, alignments: [.left, .right],
                                  rows: [[NSAttributedString(string: "Case"), NSAttributedString(string: "Result")],
                                         [NSAttributedString(string: "retry"), NSAttributedString(string: "ok")]])
        let rowContent = content("placeholder — overridden by the hand-built `.table` segment below")
        let factory = factory()
        let cell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: 393, height: 300))
        let window = UIWindow(frame: cell.frame)
        window.isHidden = false
        window.addSubview(cell)
        windowsKeepingCellsRendering.append(window)

        let largeRender = TextRowRender(content: rowContent, segments: [.table(table)], layout: .fixed(height: 300),
                                        timestampText: "12:00", style: TimelineTextStyle(sizeCategory: .large))
        cell.configure(render: largeRender, factory: factory, onRetry: { _ in })
        cell.layoutIfNeeded()
        let tableView = cell.segmentViewsForTesting[0]
        let sizeAtLarge = tableView.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))

        // Same table value, deliberately NOT calling prepareForReuse() —
        // this reproduces `reconfigureItems`, not cell recycling.
        let hugeRender = TextRowRender(content: rowContent, segments: [.table(table)], layout: .fixed(height: 300),
                                       timestampText: "12:00",
                                       style: TimelineTextStyle(sizeCategory: .accessibilityExtraExtraExtraLarge))
        cell.configure(render: hugeRender, factory: factory, onRetry: { _ in })
        let sizeAtHuge = tableView.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))

        XCTAssertNotEqual(sizeAtLarge, sizeAtHuge,
                          "the hosted table must re-render at the new Dynamic Type size, even with an unchanged table")
    }

    func test_prepareForReuse_clearsSelectionAndClosures() throws {
        var retriedItemID: String?
        let rowContent = content("This one failed", own: true, state: .failed(reason: "offline"))
        let factory = factory()
        guard case .text(let render) = TimelineMeasurer(factory: factory).measure(
            .text(rowContent), width: 393, style: style) else { return XCTFail() }
        let cell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: 393, height: render.layout.rowHeight))
        let window = UIWindow(frame: cell.frame)
        window.makeKeyAndVisible()
        window.addSubview(cell)
        windowsKeepingCellsRendering.append(window)
        cell.configure(render: render, factory: factory, onRetry: { retriedItemID = $0 })
        cell.layoutIfNeeded()

        let textView = try XCTUnwrap(cell.segmentViewsForTesting.first as? UITextView)
        textView.selectedTextRange = textView.textRange(from: textView.beginningOfDocument, to: textView.endOfDocument)
        XCTAssertTrue(textView.becomeFirstResponder())
        XCTAssertNotNil(textView.selectedTextRange)

        cell.prepareForReuse()

        XCTAssertNil(textView.selectedTextRange)
        XCTAssertFalse(textView.isFirstResponder)
        XCTAssertNil(cell.render)
        XCTAssertTrue(cell.sendStateForTesting.isHidden, "reset to the default .sent state")
        cell.sendStateForTesting.sendActions(for: .primaryActionTriggered)
        XCTAssertNil(retriedItemID, "the stale onRetry closure must not fire after reuse")
    }

    /// A code segment memoizes its `attributedText` by (code, style)
    /// (`CodeBlockSegmentView.configure`) so a reused cell whose next row
    /// shows byte-identical code no longer implicitly clears the previous
    /// selection via reassignment — `prepareForReuse` must clear it directly.
    func test_prepareForReuse_clearsCodeBlockSelection() throws {
        let cell = cell(content("Run:\n\n```swift\nlet x = 1\n```"))
        let codeSegment = try XCTUnwrap(cell.segmentViewsForTesting.first { $0 is CodeBlockSegmentView }
            as? CodeBlockSegmentView)
        let codeTextView = codeSegment.codeTextView
        codeTextView.selectedTextRange = codeTextView.textRange(from: codeTextView.beginningOfDocument,
                                                                 to: codeTextView.endOfDocument)
        XCTAssertNotNil(codeTextView.selectedTextRange)

        cell.prepareForReuse()

        XCTAssertNil(codeTextView.selectedTextRange)
    }
}
