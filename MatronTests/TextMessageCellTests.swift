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

    /// Kept alive for the life of the test: a `.table` segment hosts SwiftUI
    /// `Grid` content through a plain `UIHostingController` (Task 17's own
    /// choice — `UIHostingConfiguration`'s content view never installs its
    /// SwiftUI child off-window at all). `Grid` specifically renders empty
    /// on a layout pass that happens before the view is ever in a window
    /// (confirmed empirically — plain text/HStack content survives it,
    /// `Grid` doesn't) — production cells never hit this (a
    /// `UICollectionView` only configures a cell once it's already in the
    /// window), but this test builds `TextMessageCell` bare, so it must
    /// supply the window itself before the first `layoutIfNeeded()`.
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
}
