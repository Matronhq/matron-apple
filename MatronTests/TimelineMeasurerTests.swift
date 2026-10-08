import XCTest
import SwiftUI
import UIKit
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem
@testable import Matron

@MainActor
final class TimelineMeasurerTests: XCTestCase {
    private let style = TimelineTextStyle(sizeCategory: .large)

    private func measurer() -> TimelineMeasurer {
        let viewModel = TimelineFixtures.viewModel(LiveTimelineFixture())
        return TimelineMeasurer(factory: HostedRowFactory(viewModel: viewModel, actions: .inert,
                                                          environment: TimelineHostedEnvironment()))
    }

    func test_hostedSizer_measuresIdealHeight() {
        XCTAssertEqual(HostedSizer().height(of: Color.clear.frame(height: 37), width: 300, sizeCategory: .large), 37)
    }

    func test_hostedSizer_wrapsToTheWidth() {
        let text = Text(String(repeating: "wrap me ", count: 40))
        let sizer = HostedSizer()
        XCTAssertGreaterThan(sizer.height(of: text, width: 150, sizeCategory: .large),
                             sizer.height(of: text, width: 600, sizeCategory: .large))
    }

    func test_separatorRow_measuresLikeASwiftUIHost() {
        let date = TimelineFixtures.base
        let content = TimelineRowContent.hosted(HostedRowContent(row: .separator(date: date), subtaskChild: nil,
                                                                 hasMultipleSenders: false, imagePixelSize: nil))
        let host = UIHostingController(rootView: DateSeparator(date: date)
            .fixedSize(horizontal: false, vertical: true)
            .timelineDynamicTypeSize(.large))
        let expected = ceil(host.sizeThatFits(in: CGSize(width: 393, height: CGFloat.greatestFiniteMagnitude)).height)
        XCTAssertEqual(measurer().measure(content, width: 393, style: style).height, expected)
    }

    func test_textRowWithPills_isMeasuredOnMain_withAPillsFrame() {
        let text = TextRowContent(itemID: "1", body: "See [Auth](matron://convo/auth-1).", isOwn: false,
                                  sendState: .sent, timestamp: TimelineFixtures.base, avatarSender: nil,
                                  senderLabel: "matron", pills: [ConversationLinkRef(id: "auth-1", text: "Auth")])
        let measurer = measurer()
        XCTAssertNil(measurer.backgroundTextRender(text, width: 393, style: style))
        guard case .text(let render) = measurer.measure(.text(text), width: 393, style: style) else {
            return XCTFail("text rows measure as renders")
        }
        XCTAssertGreaterThan(render.layout.pillsFrame?.height ?? 0, 0)
    }

    func test_footerHeight_isPositive() {
        XCTAssertGreaterThan(measurer().footerHeight(label: "Thinking…", width: 393, style: style), 0)
    }

    /// Regression: an off-window `UIHostingController` ignores
    /// `traitOverrides.preferredContentSizeCategory` entirely — it measures
    /// at whatever Dynamic Type size the simulator/device is currently set
    /// to, not the `sizeCategory` argument. `HostedSizer` must use the
    /// `\.dynamicTypeSize` environment value instead, which does reach an
    /// off-window host.
    func test_hostedSizer_scalesWithDynamicTypeSize() {
        let text = Text(String(repeating: "wrap me ", count: 40))
        let sizer = HostedSizer()
        XCTAssertGreaterThan(sizer.height(of: text, width: 300, sizeCategory: .accessibilityExtraExtraExtraLarge),
                             sizer.height(of: text, width: 300, sizeCategory: .large))
    }
}
