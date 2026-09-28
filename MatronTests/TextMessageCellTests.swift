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

    /// A cell in a window that belongs to the scene, so the scene's safe
    /// area reaches it like it reaches a cell in the collection view. At
    /// `y` 0 the top safe area (status bar, Dynamic Island) overlaps the
    /// cell; mid-screen nothing does.
    private func sceneCell(_ content: TextRowContent, atY y: CGFloat) throws -> TextMessageCell {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let factory = factory()
        guard case .text(let render) = TimelineMeasurer(factory: factory).measure(
            .text(content), width: 393, style: style) else { throw XCTSkip("text rows measure as renders") }
        let cell = TextMessageCell(frame: CGRect(x: 0, y: y, width: 393, height: render.layout.rowHeight))
        let controller = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.addSubview(cell)
        cell.configure(render: render, factory: factory, onRetry: { _ in })
        for _ in 0..<5 {
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return cell
    }

    /// Where the first hosted piece (a pills row, a table) has its rendered
    /// views, in the cell's coordinates.
    private func pillPieces(in cell: TextMessageCell) throws -> [String] {
        func hosting(in view: UIView) -> UIView? {
            if String(describing: type(of: view)).contains("UIHostingContentView") { return view }
            for subview in view.subviews {
                if let found = hosting(in: subview) { return found }
            }
            return nil
        }
        let pills = try XCTUnwrap(hosting(in: cell), "the piece is hosted SwiftUI content")
        var pieces: [String] = []
        func visit(_ view: UIView) {
            for subview in view.subviews {
                let frame = subview.convert(subview.bounds, to: cell)
                pieces.append(String(format: "%@ %.1f %.1f %.1f %.1f", String(describing: type(of: subview)),
                                     frame.minX, frame.minY, frame.width, frame.height))
                visit(subview)
            }
        }
        visit(pills)
        return pieces
    }

    /// A row's pills span its full width along its bottom edge. A cell
    /// that sits in a safe area (under the navigation bar as it scrolls,
    /// beside the notch in landscape) must draw them where the layout put
    /// them: `UIHostingConfiguration` lays its content out inside the safe
    /// area unless told otherwise.
    func test_pillsRow_staysPut_whenTheCellSitsInASafeArea() throws {
        let pillsContent = content("See [Auth refactor](matron://convo/auth-1).",
                                   pills: [ConversationLinkRef(id: "auth-1", text: "Auth refactor")])
        let clear = try sceneCell(pillsContent, atY: 300)
        let under = try sceneCell(pillsContent, atY: 0)
        XCTAssertEqual(clear.safeAreaInsets, .zero, "precondition: nothing overlaps a cell mid-screen")
        XCTAssertGreaterThan(under.safeAreaInsets.top, 0, "precondition: the top safe area overlaps this cell")
        let expected = try pillPieces(in: clear)
        XCTAssertFalse(expected.isEmpty, "precondition: the pills row rendered")
        XCTAssertEqual(try pillPieces(in: under), expected,
                       "a safe area must not move the pills inside their row (cell safe area \(under.safeAreaInsets))")
    }

    /// The same for a table inside a message: it is hosted the same way.
    func test_table_staysPut_whenTheCellSitsInASafeArea() throws {
        let tableContent = content("| Name | Value |\n| --- | --- |\n| one | 1 |\n| two | 2 |")
        let clear = try sceneCell(tableContent, atY: 300)
        let under = try sceneCell(tableContent, atY: 0)
        XCTAssertEqual(clear.safeAreaInsets, .zero, "precondition: nothing overlaps a cell mid-screen")
        XCTAssertGreaterThan(under.safeAreaInsets.top, 0, "precondition: the top safe area overlaps this cell")
        let expected = try pillPieces(in: clear)
        XCTAssertFalse(expected.isEmpty, "precondition: the table rendered")
        XCTAssertEqual(try pillPieces(in: under), expected,
                       "a safe area must not move a table inside its row (cell safe area \(under.safeAreaInsets))")
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
