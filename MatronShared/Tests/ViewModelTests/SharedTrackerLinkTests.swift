import XCTest
import MatronJournal
import MatronModels
@testable import MatronViewModels

/// Another person's shareable link, read through the journal for the
/// read-only viewer.
final class SharedTrackerLinkTests: XCTestCase {
    private let link = TrackerLinkPath(user: "bob", num: 12)

    private func loader(_ lookup: NumberLookup?, item: TrackerItem? = nil, comments: [TrackerComment] = [],
                        mission: MissionDetail? = nil, fail: Bool = false) -> SharedTrackerLinkLoader {
        SharedTrackerLinkLoader(
            lookup: { user, num in
                XCTAssertEqual(user, "bob"); XCTAssertEqual(num, 12)
                if fail { throw JournalAPIError.transport("offline") }
                guard let lookup else { throw JournalAPIError.notFound }
                return lookup
            },
            item: { id in
                guard let item, item.id == id else { throw JournalAPIError.notFound }
                return (item, comments)
            },
            mission: { id in
                guard let mission, mission.mission.id == id else { throw JournalAPIError.notFound }
                return mission
            })
    }

    func test_aSharedItem_showsItsBodyAndComments_butNotStatusChanges() async {
        let item = TrackerItem(id: "it_9", num: 12, kind: .question, state: .closed, resolution: .answered,
                               title: "Which cover?", body: "Red or blue", originConvoID: "")
        let comments = [
            TrackerComment(id: "c1", itemID: "it_9", author: .agent, body: "Blue, I think", createdAt: Date(timeIntervalSince1970: 10)),
            TrackerComment(id: "c2", itemID: "it_9", author: .user, kind: .status, body: "", createdAt: Date(timeIntervalSince1970: 20)),
            TrackerComment(id: "c3", itemID: "it_9", author: .user, body: "Blue it is", createdAt: Date(timeIntervalSince1970: 30)),
        ]
        let state = await loader(NumberLookup(kind: .item, id: "it_9", num: 12, ownerName: "bob"),
                                 item: item, comments: comments).load(link)
        guard case .loaded(let p) = state else { return XCTFail("\(state)") }
        XCTAssertEqual(p.heading, "Question #12 · bob's tracker")
        XCTAssertEqual(p.status, "Closed · answered")
        XCTAssertEqual(p.body, "Red or blue")
        XCTAssertEqual(p.entriesHeading, "Comments")
        XCTAssertEqual(p.entries.map(\.heading), ["Agent", "bob"])
        XCTAssertEqual(p.entries.map(\.body), ["Blue, I think", "Blue it is"])
    }

    func test_aSharedMission_andAMilestoneOnIt_showTheMissionWithItsMilestonesNewestFirst() async {
        let mission = Mission(id: "ms_1", num: 7, title: "Launch", body: "Ship it", originConvoID: "",
                              status: "Waiting on review")
        let milestones = [
            Milestone(id: "ml_1", missionID: "ms_1", num: 8, kind: .progress, title: "Built", convoID: "", seq: 1,
                      createdAt: Date(timeIntervalSince1970: 10)),
            Milestone(id: "ml_2", missionID: "ms_1", num: 12, kind: .progress, title: "Uploaded", convoID: "", seq: 2,
                      createdAt: Date(timeIntervalSince1970: 20)),
        ]
        let detail = MissionDetail(mission: mission, milestones: milestones, items: [], conversations: [])
        let viaMilestone = await loader(NumberLookup(kind: .milestone, id: "ml_2", num: 12,
                                                     mission: .init(id: "ms_1", num: 7)), mission: detail).load(link)
        guard case .loaded(let p) = viaMilestone else { return XCTFail("\(viaMilestone)") }
        XCTAssertEqual(p.heading, "Mission #7 · bob's tracker", "the owner falls back to the link's user")
        XCTAssertEqual(p.body, "Waiting on review\n\nShip it")
        XCTAssertEqual(p.entries.map(\.heading), ["Uploaded", "Built"])
    }

    func test_notShared_aProject_andAFailedRead_sayEachApart() async {
        let notShared = await loader(nil).load(link)
        XCTAssertEqual(notShared, .notShared)
        let project = await loader(NumberLookup(kind: .project, id: "pj_1")).load(link)
        XCTAssertEqual(project, .unsupported(kindLabel: "Project"))
        let orphan = await loader(NumberLookup(kind: .milestone, id: "ml_1")).load(link)
        XCTAssertEqual(orphan, .unsupported(kindLabel: "Milestone"))
        let failed = await loader(nil, fail: true).load(link)
        XCTAssertEqual(failed, .failed)
    }

    @MainActor
    func test_aLinkInsideTheViewer_showsThatPersonsNumber_atItsWebAddress() async {
        var asked: [Int] = []
        let loader = SharedTrackerLinkLoader(lookup: { _, num in asked.append(num); throw JournalAPIError.notFound },
                                             item: { _ in throw JournalAPIError.notFound },
                                             mission: { _ in throw JournalAPIError.notFound })
        let model = SharedTrackerLinkViewModel(link: link, url: URL(string: "https://journal.example.com/u/bob/12/")!,
                                               loader: loader)
        await model.showSameOwner(30)
        XCTAssertEqual(model.link, TrackerLinkPath(user: "bob", num: 30))
        XCTAssertEqual(model.url.absoluteString, "https://journal.example.com/u/bob/30")
        XCTAssertEqual(model.state, .notShared)
        XCTAssertEqual(asked, [30])
    }

    @MainActor
    func test_aSlowerEarlierLoad_neverReplacesALaterOne() async {
        let gate = AsyncGate()
        let loader = SharedTrackerLinkLoader(
            lookup: { _, num in
                if num == 12 { await gate.wait() }
                throw num == 12 ? JournalAPIError.transport("late") : JournalAPIError.notFound
            },
            item: { _ in throw JournalAPIError.notFound }, mission: { _ in throw JournalAPIError.notFound })
        let model = SharedTrackerLinkViewModel(link: link, url: URL(string: "https://journal.example.com/u/bob/12")!,
                                               loader: loader)
        let first = Task { await model.load() }
        while !(await gate.isWaiting) { await Task.yield() }
        await model.showSameOwner(13)
        XCTAssertEqual(model.state, .notShared)
        await gate.open()
        await first.value
        XCTAssertEqual(model.state, .notShared, "the earlier read for 12 finished last but is dropped")
    }
}

/// Holds one caller until `open()`.
private actor AsyncGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false
    var isWaiting: Bool { waiter != nil }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}
