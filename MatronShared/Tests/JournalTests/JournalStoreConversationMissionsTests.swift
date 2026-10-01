import XCTest
import GRDB
import MatronModels
@testable import MatronJournal

final class JournalStoreConversationMissionsTests: XCTestCase {
    private func makeStore() throws -> JournalStore { try JournalStore(databaseURL: nil, ownSender: "user:dan") }

    private func mission(_ id: String, num: Int, origin: String = "c-other", state: MissionState = .open) -> Mission {
        Mission(id: id, num: num, state: state, title: "M\(num)", originConvoID: origin,
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
    }

    private func link(_ m: Mission, current: Bool = false, joined: TimeInterval = 10, ended: TimeInterval? = nil,
                      how: String = "joined") -> ConversationMissionLink {
        ConversationMissionLink(mission: m, isCurrent: current, isActive: ended == nil,
                                joinedAt: Date(timeIntervalSince1970: joined),
                                endedAt: ended.map { Date(timeIntervalSince1970: $0) }, how: how)
    }

    private func conversation(_ store: JournalStore, _ id: String, missionID: String? = nil, known: Bool = false,
                              count: Int? = nil) throws {
        try store.refreshSummaries([ConvoSummaryDTO(id: id, title: "Chat \(id)", sessionState: "running", lastSeq: 1,
                                                    snippet: "", createdAt: 1, missionID: missionID,
                                                    missionIDKnown: known, missionCount: count)])
    }

    func testReplacedLinksComeBackAsSections() throws {
        let store = try makeStore()
        try conversation(store, "c1", missionID: "ms_2", known: true, count: 3)
        try store.replaceConversationMissionLinks(convoID: "c1", [
            link(mission("ms_1", num: 61), joined: 5, ended: 8, how: "origin"),
            link(mission("ms_2", num: 62), current: true, joined: 20),
            link(mission("ms_3", num: 63), joined: 30),
        ])
        let sections = try store.conversationMissions(convoID: "c1").sections
        XCTAssertEqual(sections.current?.id, "ms_2")
        XCTAssertEqual(sections.alsoOn.map(\.id), ["ms_3"])
        XCTAssertEqual(sections.earlier.map(\.id), ["ms_1"])
        XCTAssertEqual(try store.mission(id: "ms_3")?.title, "M63", "an uncached mission is cached from the link row")
    }

    func testReplaceDropsLinksTheServerNoLongerReturnsAndKeepsDetailTitles() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61), mission("ms_2", num: 62)])
        try store.replaceMissionConversations(missionID: "ms_1", [
            MissionConversation(id: "c1", title: "Detail title", box: "greg", state: "running",
                                otherMissions: [MissionOtherLink(id: "ms_2", num: 62, isCurrent: true)])])
        try store.replaceMissionConversations(missionID: "ms_2", [
            MissionConversation(id: "c1", title: "Detail title", box: "greg", state: "running")])
        try store.replaceConversationMissionLinks(convoID: "c1", [link(mission("ms_1", num: 61), current: true)])
        XCTAssertEqual(try store.missionConversations(missionID: "ms_2"), [], "the server no longer links ms_2")
        let kept = try XCTUnwrap(store.missionConversations(missionID: "ms_1").first)
        XCTAssertEqual(kept.title, "Detail title"); XCTAssertEqual(kept.box, "greg")
        XCTAssertTrue(kept.isCurrent)
        XCTAssertEqual(kept.otherMissions.map(\.num), [62], "a link refresh never wipes the detail's other_missions")
    }

    /// The header can draw its chip from the snapshot before any fetch.
    func testSnapshotPointerMarksCurrentBeforeLinksAreFetched() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61)])
        try conversation(store, "c1", missionID: "ms_1", known: true, count: 3)
        let missions = try store.conversationMissions(convoID: "c1")
        XCTAssertEqual(missions.sections.current?.id, "ms_1")
        XCTAssertEqual(missions.othersCount, 2, "the snapshot's count knows about the other two")
    }

    /// PR 278 review: after a switch, only the NEW mission's detail is
    /// refetched, so its row says current while the old mission's cached row
    /// still did too — and the title tap opened the old one. Marking a row
    /// current un-marks the conversation's rows under other missions.
    func testASwitchLeavesExactlyOneCurrentMission() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61), mission("ms_2", num: 62)])
        try store.replaceMissionConversations(missionID: "ms_1", [
            MissionConversation(id: "c1", title: "S", box: nil, state: "running", isCurrent: true)])
        try store.replaceMissionConversations(missionID: "ms_2", [
            MissionConversation(id: "c1", title: "S", box: nil, state: "running", isCurrent: true)])
        try conversation(store, "c1", missionID: "ms_2", known: true, count: 2)
        let missions = try store.conversationMissions(convoID: "c1")
        XCTAssertEqual(missions.links.filter(\.isCurrent).map(\.id), ["ms_2"])
        XCTAssertEqual(missions.sections.current?.id, "ms_2")
        XCTAssertEqual(missions.sections.alsoOn.map(\.id), ["ms_1"])
    }

    /// Review Focus: an old journal (no link data, no snapshot fields) keeps
    /// today's derivation — origin first.
    func testLegacyDerivationStandsInWhenNoLinksAreKnown() throws {
        let store = try makeStore()
        try conversation(store, "c1")
        try store.upsertMissions([mission("ms_1", num: 61, origin: "c1")])
        XCTAssertEqual(try store.conversationMissions(convoID: "c1").sections.current?.id, "ms_1")
        try conversation(store, "c9")
        XCTAssertTrue(try store.conversationMissions(convoID: "c9").sections.isEmpty)
    }

    /// A new journal that says "no current mission" (`mission_id: null`,
    /// count present) must NOT fall back to the origin guess.
    func testANewJournalsNullPointerIsNotSecondGuessed() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61, origin: "c1")])
        try conversation(store, "c1", missionID: nil, known: true, count: 1)
        try store.replaceConversationMissionLinks(convoID: "c1", [link(mission("ms_1", num: 61, origin: "c1"), ended: 50)])
        let sections = try store.conversationMissions(convoID: "c1").sections
        XCTAssertNil(sections.current)
        XCTAssertEqual(sections.earlier.map(\.id), ["ms_1"])
    }

    func testStreamEmitsOnALinkChange() async throws {
        let store = try makeStore()
        try conversation(store, "c1", missionID: nil, known: true, count: 0)
        var iterator = store.missionsStream(convoID: "c1").makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.links, [])
        try store.replaceConversationMissionLinks(convoID: "c1", [link(mission("ms_1", num: 61), current: true)])
        let second = await iterator.next()
        XCTAssertEqual(second?.sections.current?.id, "ms_1")
    }
}
