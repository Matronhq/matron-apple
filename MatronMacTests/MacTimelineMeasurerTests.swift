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

    func test_cacheHitsOnlyForEqualContent() {
        let cache = MacTimelineMeasureCache(countLimit: 10)
        let a = TimelineRowContent.hosted(HostedRowContent(row: .separator(date: Date(timeIntervalSince1970: 0)),
                                                           subtaskChild: nil, hasMultipleSenders: false, imagePixelSize: nil))
        cache.store(.hosted(30), roomID: "r", content: a, width: 500)
        XCTAssertEqual(cache.measurement(roomID: "r", content: a, width: 500)?.height, 30)
        XCTAssertNil(cache.measurement(roomID: "r", content: a, width: 501))
    }
}
