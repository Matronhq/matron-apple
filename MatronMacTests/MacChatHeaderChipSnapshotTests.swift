#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronDesignSystem
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
/// long mission title truncates inside a capped chip instead of running
/// over the model cluster — and (Dan, 2026-10-01) the chat title has the
/// room first, the chip narrowing to "#4791 +2" before the title truncates.
@MainActor
final class MacChatHeaderChipSnapshotTests: XCTestCase {
    private static let longTitle =
        "mac: a mission switch never mixes missions; Done loads instead of showing Show more over nothing"
    private static let longChatTitle = "Missions Navigation Refinement and the Coordinator check-ins"

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

    private func header(missions: ConversationMissions, width: CGFloat,
                        title: String = "Projects on the Mac") -> some View {
        let model = MacChatHeaderModel()
        model.props = MacChatToolbarProps(
            roomID: "c1", publisher: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: title, boxName: nil, styledTitle: nil, accessibilityTitle: nil,
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

    func testChipWidthRunsFromNumberOnlyToTheCap() {
        func width(_ proposed: CGFloat?, full: CGFloat = 600) -> CGFloat {
            MacMissionChipWidth.width(proposed: proposed, numberOnly: 70, full: full, maxWidth: 240,
                                      minimumNameWidth: 40)
        }
        XCTAssertEqual(width(nil), 240, "the header proposes nothing; the cap still applies")
        XCTAssertEqual(width(nil, full: 150), 150, "a short name is never padded out to the cap")
        XCTAssertEqual(width(0), 70, "never narrower than number-only")
        XCTAssertEqual(width(160), 160, "between the two, the name truncates")
        XCTAssertEqual(width(500), 240)
        XCTAssertEqual(width(100), 70, "too little room for the name: number-only, not a sliver of it")
        XCTAssertEqual(width(90, full: 95), 70)
        XCTAssertEqual(width(95, full: 95), 95, "a whole short name is not a sliver")
    }

    private func chipToolbar(missionTitle: String) -> MacChatToolbar {
        let strip = SubChatStripViewModel(chat: FakeChatForChip(), parentConvoID: "c1")
        return MacChatToolbar(props: MacChatToolbarProps(
            roomID: "c1", publisher: UUID(), title: "T", boxName: nil, styledTitle: nil, accessibilityTitle: nil,
            status: nil, stripViewModel: strip, missions: missions(title: missionTitle), projectTitles: [:],
            needsYouCount: 0, itemsAvailable: true,
            actions: .init(onOpenSubChat: { _ in }, onCompact: {}, onOpenMission: { _ in }, onOpenProject: { _ in },
                           showMediaBrowser: .constant(false), showItemsPane: .constant(false))))
    }

    private func width(of view: some View, proposed: CGFloat?) -> CGFloat {
        NSHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: proposed ?? .greatestFiniteMagnitude, height: 52)).width
    }

    /// The chip's narrowest and widest, as the header's layout measures it.
    func testTheChipNarrowsToNumberOnlyAndWidensToTheCap() {
        let chip = chipToolbar(missionTitle: Self.longTitle).missionChipItem
        let widest = width(of: chip, proposed: nil)
        let narrowest = width(of: chip, proposed: 0)
        let chrome = widest - MacChatToolbar.missionChipMaxWidth
        XCTAssertGreaterThan(chrome, 0)
        XCTAssertLessThanOrEqual(chrome, 60, "an uncapped chip measured \(widest) pt")
        let numberOnly = width(of: MissionChipLabel(missions: missions(title: Self.longTitle), numberOnly: true),
                               proposed: nil)
        XCTAssertEqual(narrowest, numberOnly + chrome, accuracy: 1, "the floor is \"#4791 +2\", nothing more")
    }

    func testHeaderChipShort() {
        assertVariants(of: header(missions: missions(title: "Promo branch"), width: 800), named: "header-chip-short-800")
    }

    /// The title's ideal is wider than the chip leaves at its fullest:
    /// number-only chip, the title truncating into the rest.
    func testHeaderChipLongTitle() {
        assertVariants(of: header(missions: missions(title: Self.longTitle), width: 800, title: Self.longChatTitle),
                       named: "header-chip-long-800")
    }

    /// Room for the whole title: it shows in full, the chip takes what is
    /// left up to its cap.
    func testHeaderChipLongTitleWide() {
        assertVariants(of: header(missions: missions(title: Self.longTitle), width: 1100, title: Self.longChatTitle),
                       named: "header-chip-long-1100")
    }
}
#endif
