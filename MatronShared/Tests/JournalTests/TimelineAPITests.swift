import XCTest
import MatronModels
@testable import MatronJournal

final class TimelineAPITests: XCTestCase {
    private func makeStubbedAPI(status: Int = 200, body: [String: Any]) -> (JournalAPI, ItemsStubURLProtocol.Type) {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                             urlSession: URLSession(configuration: config), token: "t")
        return (api, ItemsStubURLProtocol.self)
    }

    private func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

    private func project(_ id: String = "pj_a", num: Int = 7, title: String = "Garden shed") -> [String: Any] {
        ["id": id, "num": num, "title": title]
    }

    // MARK: decoding

    func testWeeksDecodeWithTheNextCursor() throws {
        let page = try JournalAPI.decodeTimelineWeeks([
            "weeks": [
                ["week": "2026-11-02", "start": 1_762_041_600_000, "end": 1_762_646_400_000,
                 "sentence": "Garden shed and Bike moved.", "moved": 2],
                ["week": "2026-10-26", "start": 1_761_436_800_000, "end": 1_762_041_600_000,
                 "sentence": "A quiet week.", "moved": 0],
            ],
            "next_before": "2026-10-26",
        ])
        XCTAssertEqual(page.weeks.map(\.week), ["2026-11-02", "2026-10-26"])
        XCTAssertEqual(page.weeks[0].start, date(1_762_041_600_000))
        XCTAssertEqual(page.weeks[0].end, date(1_762_646_400_000))
        XCTAssertEqual(page.weeks[0].sentence, "Garden shed and Bike moved.")
        XCTAssertEqual(page.weeks[0].moved, 2)
        XCTAssertEqual(page.nextBefore, "2026-10-26")
    }

    func testWeeksNullNextBeforeIsNil() throws {
        let page = try JournalAPI.decodeTimelineWeeks(["weeks": [], "next_before": NSNull()])
        XCTAssertEqual(page.weeks, [])
        XCTAssertNil(page.nextBefore)
    }

    func testAWeekRowWithoutAKeyIsDroppedAndTheRestKept() throws {
        let page = try JournalAPI.decodeTimelineWeeks(["weeks": [
            ["start": 1, "end": 2, "sentence": "x", "moved": 1],
            ["week": "2026-10-26", "start": 1, "end": 2, "sentence": "y", "moved": 1],
        ], "next_before": NSNull()])
        XCTAssertEqual(page.weeks.map(\.week), ["2026-10-26"])
    }

    func testAMalformedWeeksResponseIsATransportError() {
        XCTAssertThrowsError(try JournalAPI.decodeTimelineWeeks(["foo": 1])) { error in
            guard case JournalAPIError.transport = error else { return XCTFail("got \(error)") }
        }
    }

    func testAWeekDecodesStoriesAndAlso() throws {
        let week = try JournalAPI.decodeTimelineWeek([
            "week": "2026-11-02", "start": 1_762_041_600_000, "end": 1_762_646_400_000,
            "final": false, "lede": NSNull(),
            "stories": [
                ["project": project(), "sentence": "Roof is on", "next": NSNull(),
                 "needs_you": [["id": "it_1", "num": 41, "title": "Pick a colour"]],
                 "media": ["blob_id": "bl_1", "content_type": "video/mp4", "name": "walkthrough.mp4"]],
                ["project": project("pj_b", num: 9, title: "Bike"), "sentence": NSNull(), "next": "Order brakes",
                 "needs_you": [], "media": NSNull()],
            ],
            "also": [["id": "pj_c", "num": 11, "title": "Taxes", "moved": 1]],
        ])
        XCTAssertEqual(week.week, "2026-11-02")
        XCTAssertFalse(week.final)
        XCTAssertNil(week.lede)
        XCTAssertEqual(week.stories.count, 2)
        let first = week.stories[0]
        XCTAssertEqual(first.project, TimelineProjectRef(id: "pj_a", num: 7, title: "Garden shed"))
        XCTAssertEqual(first.sentence, "Roof is on")
        XCTAssertNil(first.next)
        XCTAssertEqual(first.needsYou, [TimelineItemRef(id: "it_1", num: 41, title: "Pick a colour")])
        XCTAssertEqual(first.media, TimelineMedia(blobID: "bl_1", contentType: "video/mp4", name: "walkthrough.mp4"))
        XCTAssertTrue(try XCTUnwrap(first.media).isVideo)
        let second = week.stories[1]
        XCTAssertNil(second.sentence, "a project that moved without a milestone has no sentence")
        XCTAssertEqual(second.next, "Order brakes")
        XCTAssertEqual(second.needsYou, [])
        XCTAssertNil(second.media)
        XCTAssertEqual(week.also, [TimelineProjectRef(id: "pj_c", num: 11, title: "Taxes")])
    }

    private func week(stories: [[String: Any]]) throws -> TimelineWeek {
        try JournalAPI.decodeTimelineWeek([
            "week": "2026-11-02", "start": 1, "end": 2, "final": false, "stories": stories, "also": [],
        ])
    }

    func testAWrittenStoryDecodesTitleProjectsAndDoneItems() throws {
        let shed = project(), bike = project("pj_b", num: 9, title: "Bike")
        let story = try XCTUnwrap(week(stories: [[
            "project": shed, "title": "  Shed and bike weekend ", "projects": [shed, ["num": 3, "title": "No id"], bike],
            "sentence": "x", "next": NSNull(),
            "needs_you": [["id": "it_1", "num": 41, "title": "Pick a colour", "done": false],
                          ["id": "it_2", "num": 42, "title": "Order brakes", "done": true]],
            "media": NSNull(),
        ]]).stories.first)
        XCTAssertEqual(story.title, "Shed and bike weekend")
        XCTAssertEqual(story.project, TimelineProjectRef(id: "pj_a", num: 7, title: "Garden shed"))
        XCTAssertEqual(story.projects, [TimelineProjectRef(id: "pj_a", num: 7, title: "Garden shed"),
                                        TimelineProjectRef(id: "pj_b", num: 9, title: "Bike")],
                       "a project row without an id is dropped")
        XCTAssertEqual(story.needsYou.map(\.done), [false, true])
    }

    func testAStoryFromAnOlderJournalHasNoTitleOneProjectAndNothingDone() throws {
        let story = try XCTUnwrap(week(stories: [[
            "project": project(), "sentence": "x", "next": NSNull(),
            "needs_you": [["id": "it_1", "num": 41, "title": "Pick a colour"]], "media": NSNull(),
        ]]).stories.first)
        XCTAssertNil(story.title)
        XCTAssertEqual(story.projects, [story.project])
        XCTAssertEqual(story.needsYou.map(\.done), [false])
    }

    func testEmptyOrBlankWrittenFieldsFallBack() throws {
        let story = try XCTUnwrap(week(stories: [[
            "project": project(), "title": "   ", "projects": [], "needs_you": [],
        ]]).stories.first)
        XCTAssertNil(story.title, "a blank title is no title")
        XCTAssertEqual(story.projects, [story.project], "an empty projects list is just the project")
        let nulls = try XCTUnwrap(week(stories: [["project": project(), "title": NSNull(), "projects": NSNull()]]).stories.first)
        XCTAssertNil(nulls.title)
        XCTAssertEqual(nulls.projects, [nulls.project])
    }

    func testAFinalWeekWithALedeDecodes() throws {
        let week = try JournalAPI.decodeTimelineWeek([
            "week": "2026-10-26", "start": 1, "end": 2, "final": true, "lede": "A big week.",
            "stories": [], "also": [],
        ])
        XCTAssertTrue(week.final)
        XCTAssertEqual(week.lede, "A big week.")
    }

    func testAStoryWithoutAProjectIDIsDroppedAndTheRestKept() throws {
        let week = try JournalAPI.decodeTimelineWeek([
            "week": "2026-11-02", "start": 1, "end": 2, "final": true, "lede": NSNull(),
            "stories": [
                ["project": ["num": 1, "title": "No id"], "sentence": "x", "next": NSNull(), "needs_you": [], "media": NSNull()],
                ["project": project(), "sentence": "y", "next": NSNull(), "needs_you": [], "media": NSNull()],
            ],
            "also": [["num": 2, "title": "No id", "moved": 1], ["id": "pj_c", "num": 11, "title": "Taxes", "moved": 1]],
        ])
        XCTAssertEqual(week.stories.map(\.project.id), ["pj_a"])
        XCTAssertEqual(week.also.map(\.id), ["pj_c"])
    }

    func testAMalformedWeekIsATransportError() {
        XCTAssertThrowsError(try JournalAPI.decodeTimelineWeek(["foo": 1])) { error in
            guard case JournalAPIError.transport = error else { return XCTFail("got \(error)") }
        }
    }

    func testMediaIsVideoOnlyForAVideoType() throws {
        let video = try XCTUnwrap(TimelineMedia(json: ["blob_id": "b", "content_type": "video/mp4", "name": "a.mp4"]))
        let image = try XCTUnwrap(TimelineMedia(json: ["blob_id": "b", "content_type": "image/png", "name": "a.png"]))
        XCTAssertTrue(video.isVideo)
        XCTAssertFalse(image.isVideo)
    }

    func testQuietDecodesTotalRowsAndWeekly() throws {
        let list = try JournalAPI.decodeStalledList([
            "total": 12,
            "rows": [
                ["project": project(), "last_moved_at": 1_760_000_000_000,
                 "weekly": [0, 1, 3, 0, 2, 0, 0, 0], "note": NSNull()],
                ["project": ["num": 3], "last_moved_at": 1_760_000_000_000, "weekly": [], "note": NSNull()],
            ],
        ])
        XCTAssertEqual(list.total, 12)
        XCTAssertEqual(list.rows.count, 1, "the row without a project id is dropped")
        let row = list.rows[0]
        XCTAssertEqual(row.project.id, "pj_a")
        XCTAssertEqual(row.lastMovedAt, date(1_760_000_000_000))
        XCTAssertNil(row.createdAt)
        XCTAssertEqual(row.weekly, [0, 1, 3, 0, 2, 0, 0, 0])
        XCTAssertNil(row.note)
    }

    func testOpenLongDecodesCreatedAt() throws {
        let list = try JournalAPI.decodeStalledList([
            "total": 1,
            "rows": [["project": project(), "created_at": 1_750_000_000_000, "last_moved_at": 1_760_000_000_000,
                      "weekly": [1, 0, 0, 0, 0, 0, 0, 0], "note": "Waiting on permits"]],
        ])
        XCTAssertEqual(list.rows[0].createdAt, date(1_750_000_000_000))
        XCTAssertEqual(list.rows[0].note, "Waiting on permits")
    }

    func testAnOpenLongRowWithoutAMoveHasNoLastMovedAt() throws {
        let list = try JournalAPI.decodeStalledList([
            "total": 1,
            "rows": [["project": project(), "created_at": 1_750_000_000_000, "last_moved_at": NSNull(),
                      "weekly": [0, 0, 0, 0, 0, 0, 0, 0], "note": NSNull()]],
        ])
        XCTAssertEqual(list.rows.count, 1)
        XCTAssertNil(list.rows[0].lastMovedAt)
        XCTAssertEqual(list.rows[0].createdAt, date(1_750_000_000_000))
    }

    func testAWeeklyEntryThatIsNotANumberCountsAsZeroAndKeepsPositions() throws {
        let list = try JournalAPI.decodeStalledList([
            "total": 1,
            "rows": [["project": project(), "last_moved_at": 1, "weekly": [1, "x", NSNull(), 4, 0, 0, 0, 2]]],
        ])
        XCTAssertEqual(list.rows[0].weekly, [1, 0, 0, 4, 0, 0, 0, 2])
    }

    func testAWeekWithoutFinalIsNotFinal() throws {
        let week = try JournalAPI.decodeTimelineWeek(["week": "2026-11-02", "start": 1, "end": 2])
        XCTAssertFalse(week.final)
    }

    func testAMalformedStalledListIsATransportError() {
        XCTAssertThrowsError(try JournalAPI.decodeStalledList(["total": 1])) { error in
            guard case JournalAPIError.transport = error else { return XCTFail("got \(error)") }
        }
    }

    func testFinishedDecodesRowsAndCursor() throws {
        let page = try JournalAPI.decodeFinishedProjects([
            "rows": [
                ["project": project(), "finished_at": 1_760_000_000_000],
                ["project": ["id": "", "num": 2, "title": "Empty id"], "finished_at": 1_759_000_000_000],
                ["project": project("pj_b", num: 9, title: "Bike")],
            ],
            "next_before": "1759000000000:pj_b",
        ])
        XCTAssertEqual(page.rows.map(\.project.id), ["pj_a"], "rows missing a project id or a finish time are dropped")
        XCTAssertEqual(page.rows[0].finishedAt, date(1_760_000_000_000))
        XCTAssertEqual(page.nextBefore, "1759000000000:pj_b")
    }

    func testFinishedNullCursorIsNil() throws {
        let page = try JournalAPI.decodeFinishedProjects(["rows": [], "next_before": NSNull()])
        XCTAssertNil(page.nextBefore)
    }

    // MARK: requests

    func testTimelineWeeksSendsBeforeAndLimit() async throws {
        let (api, recorder) = makeStubbedAPI(body: ["weeks": [], "next_before": NSNull()])
        _ = try await api.timelineWeeks(before: "2026-10-26", limit: 4)
        let url = try XCTUnwrap(recorder.lastRequest?.url)
        XCTAssertEqual(url.path, "/timeline/weeks")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "before" }?.value, "2026-10-26")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "4")
    }

    func testTimelineWeeksWithoutParametersSendsNoQuery() async throws {
        let (api, recorder) = makeStubbedAPI(body: ["weeks": [], "next_before": NSNull()])
        _ = try await api.timelineWeeks(before: nil, limit: nil)
        XCTAssertNil(try XCTUnwrap(recorder.lastRequest?.url).query)
    }

    func testTimelineWeeks404IsNotFound() async {
        let (api, _) = makeStubbedAPI(status: 404, body: ["error": "not_found"])
        do { _ = try await api.timelineWeeks(before: nil, limit: nil); XCTFail("expected a throw") }
        catch { XCTAssertEqual(error as? JournalAPIError, .notFound) }
    }

    func testTimelineWeekGetsTheWeekKeyPath() async throws {
        let (api, recorder) = makeStubbedAPI(body: [
            "week": "2026-11-02", "start": 1, "end": 2, "final": false, "lede": NSNull(), "stories": [], "also": [],
        ])
        let week = try await api.timelineWeek("2026-11-02")
        XCTAssertEqual(week.week, "2026-11-02")
        XCTAssertEqual(try XCTUnwrap(recorder.lastRequest?.url).path, "/timeline/weeks/2026-11-02")
    }

    func testWentQuietAndOpenLongHitTheirRoutes() async throws {
        let (api, recorder) = makeStubbedAPI(body: ["total": 0, "rows": []])
        let quiet = try await api.wentQuiet()
        XCTAssertEqual(quiet.total, 0)
        XCTAssertEqual(try XCTUnwrap(recorder.lastRequest?.url).path, "/timeline/quiet")
        _ = try await api.openLong()
        XCTAssertEqual(try XCTUnwrap(recorder.lastRequest?.url).path, "/timeline/long")
    }

    func testFinishedProjectsSendsTheCursorAndLimit() async throws {
        let (api, recorder) = makeStubbedAPI(body: ["rows": [], "next_before": NSNull()])
        _ = try await api.finishedProjects(before: "1759000000000:pj_b", limit: 30)
        let url = try XCTUnwrap(recorder.lastRequest?.url)
        XCTAssertEqual(url.path, "/timeline/finished")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "before" }?.value, "1759000000000:pj_b")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "30")
    }
}
