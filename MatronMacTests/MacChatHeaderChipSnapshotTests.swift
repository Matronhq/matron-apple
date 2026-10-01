#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

private final class FakeChatForChip: ChatService, @unchecked Sendable {
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> { AsyncStream { $0.finish() } }
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> { AsyncThrowingStream { $0.finish() } }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

/// Spec §6 "header chip baselines on Mac" (PR4 review M7), pinning I2: a
/// long mission title truncates inside a capped chip instead of squeezing
/// the chat title or running over the model cluster.
@MainActor
final class MacChatHeaderChipSnapshotTests: XCTestCase {
    private static let longTitle =
        "mac: a mission switch never mixes missions; Done loads instead of showing Show more over nothing"

    private func missions(title: String) -> ConversationMissions {
        func link(_ num: Int, _ title: String, current: Bool) -> ConversationMissionLink {
            ConversationMissionLink(mission: Mission(id: "ms_\(num)", num: num, title: title, originConvoID: "c1",
                                                     projectID: "pj_1"),
                                    isCurrent: current)
        }
        return ConversationMissions(links: [link(4791, title, current: true),
                                            link(4907, "Launch day", current: false),
                                            link(4083, "Combined promo branch", current: false)])
    }

    private func header(missions: ConversationMissions, width: CGFloat) -> some View {
        let model = MacChatHeaderModel()
        model.props = MacChatToolbarProps(
            roomID: "c1", publisher: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Projects on the Mac", boxName: nil, styledTitle: nil, accessibilityTitle: nil,
            status: SessionStatus(model: "claude-opus-5-5",
                                  context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27),
                                  limits: [SessionStatus.Limit(label: "Session", percent: 39, resets: nil, resetsAt: nil)]),
            stripViewModel: SubChatStripViewModel(chat: FakeChatForChip(), parentConvoID: "c1"),
            missions: missions, projectTitles: ["pj_1": "Promo launch"], needsYouCount: 0, itemsAvailable: true,
            actions: .init(onOpenSubChat: { _ in }, onCompact: {}, onOpenMission: { _ in }, onOpenProject: { _ in },
                           showMediaBrowser: .constant(false), showItemsPane: .constant(false)))
        return MacChatHeaderBar(model: model, hitRegions: MacChatHeaderHitRegions())
            .frame(width: width, height: 52)
    }

    func testCappedWidthNeverExceedsTheCapOrTheIdeal() {
        XCTAssertEqual(MacCappedWidth.width(proposed: nil, ideal: 600, maxWidth: 240), 240,
                       "the header proposes nothing; the cap still applies")
        XCTAssertEqual(MacCappedWidth.width(proposed: nil, ideal: 120, maxWidth: 240), 120)
        XCTAssertEqual(MacCappedWidth.width(proposed: 90, ideal: 600, maxWidth: 240), 90)
    }

    /// The chip's ideal width, as the header's layout measures it.
    func testALongMissionTitleKeepsTheChipWithinItsCap() {
        let toolbar = MacChatToolbar(props: {
            let strip = SubChatStripViewModel(chat: FakeChatForChip(), parentConvoID: "c1")
            return MacChatToolbarProps(
                roomID: "c1", publisher: UUID(), title: "T", boxName: nil, styledTitle: nil, accessibilityTitle: nil,
                status: nil, stripViewModel: strip, missions: missions(title: Self.longTitle), projectTitles: [:],
                needsYouCount: 0, itemsAvailable: true,
                actions: .init(onOpenSubChat: { _ in }, onCompact: {}, onOpenMission: { _ in }, onOpenProject: { _ in },
                               showMediaBrowser: .constant(false), showItemsPane: .constant(false)))
        }())
        let host = NSHostingView(rootView: toolbar.missionChipItem)
        let ideal = host.fittingSize.width
        // Cap + the capsule's 8 pt side padding + the chevron.
        XCTAssertLessThanOrEqual(ideal, MacChatToolbar.missionChipMaxWidth + 60,
                                 "an uncapped chip measured \(ideal) pt")
    }

    func testHeaderChipShort() {
        assertVariants(of: header(missions: missions(title: "Promo branch"), width: 800), named: "header-chip-short-800")
    }

    func testHeaderChipLongTitle() {
        assertVariants(of: header(missions: missions(title: Self.longTitle), width: 800), named: "header-chip-long-800")
    }
}
#endif
