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

    func testTheMainProjectLeadsOnceEvenWhenTheListStartsElsewhere() throws {
        let shed = project(), bike = project("pj_b", num: 9, title: "Bike")
        let story = try XCTUnwrap(week(stories: [[
            "project": shed, "projects": [["num": 3, "title": "No id"], bike, shed], "sentence": "x",
        ]]).stories.first)
        XCTAssertEqual(story.projects.map(\.id), ["pj_a", "pj_b"])
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

    // MARK: marks

    func testAStoryDecodesItsMarks() throws {
        let story = try XCTUnwrap(week(stories: [[
            "project": project(), "sentence": "x", "next": NSNull(), "needs_you": [],
            "marks": ["for_you": 2, "done": 3, "next": true],
        ]]).stories.first)
        XCTAssertEqual(story.marks, TimelineMarks(forYou: 2, done: 3, next: true))
        XCTAssertFalse(story.marks.isEmpty)
    }

    func testMarksMissingFieldsAreZeroAndFalse() throws {
        let marks = try XCTUnwrap(TimelineMarks(json: ["done": 1]))
        XCTAssertEqual(marks, TimelineMarks(forYou: 0, done: 1, next: false))
        XCTAssertTrue(try XCTUnwrap(TimelineMarks(json: [:])).isEmpty)
        XCTAssertNil(TimelineMarks(json: nil))
    }

    func testAStoryWithoutMarksDerivesThemFromWhatItCarries() throws {
        let stories = try week(stories: [
            ["project": project(), "sentence": "x", "next": "Order brakes",
             "needs_you": [["id": "it_1", "num": 41, "title": "Pick a colour", "done": false],
                           ["id": "it_2", "num": 42, "title": "Order brakes", "done": true]]],
            ["project": project("pj_b", num: 9, title: "Bike"), "sentence": "y", "next": NSNull(),
             "needs_you": [], "marks": NSNull()],
        ]).stories
        XCTAssertEqual(stories[0].marks, TimelineMarks(forYou: 1, done: 0, next: true),
                       "only the items still waiting count, and nothing is known done")
        XCTAssertEqual(stories[1].marks, TimelineMarks(forYou: 0, done: 0, next: false))
        XCTAssertTrue(stories[1].marks.isEmpty)
    }

    // MARK: all projects

    func testProjectsDecodeTotalRowsAndCursor() throws {
        let list = try JournalAPI.decodeTimelineProjects([
            "total": 14,
            "rows": [
                ["project": project("pj_a", num: 7, title: "Promo launch"), "last_moved_at": 1_760_000_000_000,
                 "open_missions": 3],
                ["project": ["num": 3, "title": "No id"], "last_moved_at": 1_760_000_000_000, "open_missions": 1],
                ["project": project("pj_b", num: 9, title: "Docs site"), "last_moved_at": NSNull()],
            ],
            "next_before": "1759000000000:pj_b",
        ])
        XCTAssertEqual(list.total, 14)
        XCTAssertEqual(list.rows.map(\.project.id), ["pj_a", "pj_b"], "the row without a project id is dropped")
        XCTAssertEqual(list.rows[0].project, TimelineProjectRef(id: "pj_a", num: 7, title: "Promo launch"))
        XCTAssertEqual(list.rows[0].lastMovedAt, date(1_760_000_000_000))
        XCTAssertEqual(list.rows[0].openMissions, 3)
        XCTAssertNil(list.rows[1].lastMovedAt, "a project with no recorded move")
        XCTAssertEqual(list.rows[1].openMissions, 0)
        XCTAssertEqual(list.nextBefore, "1759000000000:pj_b")
    }

    func testProjectsNullCursorIsNilAndAMalformedListIsATransportError() throws {
        let list = try JournalAPI.decodeTimelineProjects(["total": 0, "rows": [], "next_before": NSNull()])
        XCTAssertEqual(list.rows, [])
        XCTAssertNil(list.nextBefore)
        XCTAssertThrowsError(try JournalAPI.decodeTimelineProjects(["total": 1])) { error in
            guard case JournalAPIError.transport = error else { return XCTFail("got \(error)") }
        }
    }

    // MARK: project page

    private func pageJSON(_ extra: [String: Any] = [:]) -> [String: Any] {
        var json: [String: Any] = [
            "project": ["id": "pj_a", "num": 7, "title": "Promo launch", "state": "open", "live": true],
            "sentence": "The landing page is up", "sentence_source": "milestone", "next": "Write the email",
            "needs_you": [["id": "it_1", "num": 41, "title": "Pick a headline"], ["num": 42, "title": "No id"]],
            "needs_you_total": 5,
            "media": ["blob_id": "bl_1", "content_type": "image/png", "name": "landing.png"],
            "counts": ["weeks": 6, "missions_open": 2, "missions_done": 9, "files": 4],
        ]
        json.merge(extra) { $1 }
        return json
    }

    func testAProjectPageDecodes() throws {
        let page = try JournalAPI.decodeTimelineProject(pageJSON())
        XCTAssertEqual(page.project, TimelineProjectRef(id: "pj_a", num: 7, title: "Promo launch"))
        XCTAssertTrue(page.isLive)
        XCTAssertEqual(page.state, "open")
        XCTAssertEqual(page.sentence, "The landing page is up")
        XCTAssertEqual(page.next, "Write the email")
        XCTAssertEqual(page.needsYou, [TimelineItemRef(id: "it_1", num: 41, title: "Pick a headline")],
                       "an item without an id is dropped")
        XCTAssertEqual(page.needsYouTotal, 5)
        XCTAssertEqual(page.media, TimelineMedia(blobID: "bl_1", contentType: "image/png", name: "landing.png"))
        XCTAssertEqual(page.weeks, 6)
        XCTAssertEqual(page.missionsOpen, 2)
        XCTAssertEqual(page.missionsDone, 9)
        XCTAssertEqual(page.files, 4)
        XCTAssertNil(page.mergedFromID)
    }

    func testAProjectPageReachedThroughAMergedProjectSaysWhich() throws {
        let page = try JournalAPI.decodeTimelineProject(pageJSON(["merged_from": ["id": "pj_old", "num": 3]]))
        XCTAssertEqual(page.mergedFromID, "pj_old")
        XCTAssertEqual(page.project.id, "pj_a")
    }

    func testAQuietFinishedProjectPageFallsBack() throws {
        let page = try JournalAPI.decodeTimelineProject([
            "project": ["id": "pj_b", "num": 9, "title": "Docs site", "state": "closed", "live": false],
            "sentence": NSNull(), "sentence_source": NSNull(), "next": NSNull(),
            "needs_you": [], "media": NSNull(),
        ])
        XCTAssertFalse(page.isLive)
        XCTAssertEqual(page.state, "closed")
        XCTAssertNil(page.sentence)
        XCTAssertNil(page.next)
        XCTAssertEqual(page.needsYou, [])
        XCTAssertEqual(page.needsYouTotal, 0, "a missing total counts the items sent")
        XCTAssertNil(page.media)
        XCTAssertEqual([page.weeks, page.missionsOpen, page.missionsDone, page.files], [0, 0, 0, 0])
    }

    func testAProjectPageWithoutAProjectIsATransportError() {
        XCTAssertThrowsError(try JournalAPI.decodeTimelineProject(["sentence": "x"])) { error in
            guard case JournalAPIError.transport = error else { return XCTFail("got \(error)") }
        }
    }

    // MARK: project history

    private func milestone(_ id: String, title: String) -> [String: Any] {
        ["id": id, "mission_id": "ms_1", "num": 1, "kind": "progress", "title": title, "convo_id": "cv_1",
         "seq": 12, "created_at": 1_762_100_000_000, "mission_num": 31]
    }

    func testProjectHistoryDecodesWeeksCardsAndMilestones() throws {
        let page = try JournalAPI.decodeTimelineProjectHistory([
            "weeks": [
                ["week": "2026-11-02", "start": 1_762_041_600_000, "end": 1_762_646_400_000,
                 "card": ["sentence": "The landing page is up",
                          "media": ["blob_id": "bl_1", "content_type": "image/png", "name": "landing.png"]],
                 "milestones": [milestone("ml_1", title: "Landing page live"), ["id": "ml_bad"]],
                 "more_milestones": 4],
                ["week": "2026-10-26", "start": 1_761_436_800_000, "end": 1_762_041_600_000,
                 "card": NSNull(), "milestones": [milestone("ml_2", title: "Copy drafted")]],
                ["start": 1, "end": 2, "card": NSNull(), "milestones": []],
            ],
            "next_before": "2026-10-26",
        ])
        XCTAssertEqual(page.weeks.map(\.week), ["2026-11-02", "2026-10-26"], "the week without a key is dropped")
        let first = page.weeks[0]
        XCTAssertEqual(first.start, date(1_762_041_600_000))
        XCTAssertEqual(first.end, date(1_762_646_400_000))
        XCTAssertEqual(first.sentence, "The landing page is up")
        XCTAssertEqual(first.media, TimelineMedia(blobID: "bl_1", contentType: "image/png", name: "landing.png"))
        XCTAssertEqual(first.milestones.map(\.id), ["ml_1"], "a malformed milestone is dropped")
        XCTAssertEqual(first.milestones[0].milestone.title, "Landing page live")
        XCTAssertEqual(first.milestones[0].missionNum, 31)
        XCTAssertEqual(first.moreMilestones, 4)
        let second = page.weeks[1]
        XCTAssertNil(second.sentence, "a week with no card has no sentence")
        XCTAssertNil(second.media)
        XCTAssertEqual(second.milestones.map(\.id), ["ml_2"])
        XCTAssertEqual(second.moreMilestones, 0)
        XCTAssertEqual(page.nextBefore, "2026-10-26")
    }

    func testProjectHistoryNullCursorIsNilAndAMalformedAnswerIsATransportError() throws {
        let page = try JournalAPI.decodeTimelineProjectHistory(["weeks": [], "next_before": NSNull()])
        XCTAssertEqual(page.weeks, [])
        XCTAssertNil(page.nextBefore)
        XCTAssertThrowsError(try JournalAPI.decodeTimelineProjectHistory(["foo": 1])) { error in
            guard case JournalAPIError.transport = error else { return XCTFail("got \(error)") }
        }
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

    func testTimelineProjectsSendsTheCursorAndLimit() async throws {
        let (api, recorder) = makeStubbedAPI(body: ["total": 0, "rows": [], "next_before": NSNull()])
        let list = try await api.timelineProjects(before: "1759000000000:pj_b", limit: 50)
        XCTAssertEqual(list.total, 0)
        let url = try XCTUnwrap(recorder.lastRequest?.url)
        XCTAssertEqual(url.path, "/timeline/projects")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "before" }?.value, "1759000000000:pj_b")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "50")
    }

    func testTimelineProjectGetsTheProjectPath() async throws {
        let (api, recorder) = makeStubbedAPI(body: pageJSON())
        let page = try await api.timelineProject("pj_a")
        XCTAssertEqual(page.project.id, "pj_a")
        let url = try XCTUnwrap(recorder.lastRequest?.url)
        XCTAssertEqual(url.path, "/timeline/projects/pj_a")
        XCTAssertNil(url.query)
    }

    func testTimelineProject404IsNotFound() async {
        let (api, _) = makeStubbedAPI(status: 404, body: ["error": "not_found"])
        do { _ = try await api.timelineProject("pj_a"); XCTFail("expected a throw") }
        catch { XCTAssertEqual(error as? JournalAPIError, .notFound) }
    }

    func testTimelineProjectHistorySendsTheWeekCursorAndLimit() async throws {
        let (api, recorder) = makeStubbedAPI(body: ["weeks": [], "next_before": NSNull()])
        _ = try await api.timelineProjectHistory("pj_a", before: "2026-10-26", limit: 8)
        let url = try XCTUnwrap(recorder.lastRequest?.url)
        XCTAssertEqual(url.path, "/timeline/projects/pj_a/history")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "before" }?.value, "2026-10-26")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "8")
    }

    // MARK: a week's other projects

    func testWeekProjectsDecodeRowsAndTheNextOffset() throws {
        let page = try JournalAPI.decodeTimelineWeekProjects([
            "week": "2026-11-02", "total": 30, "offset": 0, "next_offset": 24,
            "projects": [
                ["project": project(), "moved": 5, "sentence": "Roof went on.",
                 "media": ["blob_id": "b1", "content_type": "image/jpeg", "name": "roof.jpg"],
                 "marks": ["for_you": 1, "done": 2, "next": true]],
                ["project": project("pj_b", num: 8, title: "Bike"), "moved": 1, "sentence": NSNull(), "media": NSNull(),
                 "marks": ["for_you": 0, "done": 0, "next": false]],
            ],
        ])
        XCTAssertEqual(page.week, "2026-11-02")
        XCTAssertEqual(page.total, 30)
        XCTAssertEqual(page.offset, 0)
        XCTAssertEqual(page.nextOffset, 24)
        XCTAssertEqual(page.projects.map(\.project.id), ["pj_a", "pj_b"])
        XCTAssertEqual(page.projects[0].moved, 5)
        XCTAssertEqual(page.projects[0].sentence, "Roof went on.")
        XCTAssertEqual(page.projects[0].media, TimelineMedia(blobID: "b1", contentType: "image/jpeg", name: "roof.jpg"))
        XCTAssertEqual(page.projects[0].marks, TimelineMarks(forYou: 1, done: 2, next: true))
        XCTAssertNil(page.projects[1].sentence)
        XCTAssertNil(page.projects[1].media)
        XCTAssertTrue(page.projects[1].marks.isEmpty)
        // As a card: the name, the sentence, the media and the marks.
        XCTAssertEqual(page.projects[0].story.project.title, "Garden shed")
        XCTAssertEqual(page.projects[0].story.marks, page.projects[0].marks)
    }

    func testWeekProjectsLastPageHasNoNextOffsetAndBadRowsAreDropped() throws {
        let page = try JournalAPI.decodeTimelineWeekProjects([
            "week": "2026-11-02", "total": 2, "offset": 24, "next_offset": NSNull(),
            "projects": [["moved": 1], ["project": project(), "moved": 2]],
        ])
        XCTAssertNil(page.nextOffset)
        XCTAssertEqual(page.projects.map(\.project.id), ["pj_a"])
        XCTAssertTrue(page.projects[0].marks.isEmpty, "missing marks are none")
    }

    func testAMalformedWeekProjectsResponseIsATransportError() {
        XCTAssertThrowsError(try JournalAPI.decodeTimelineWeekProjects(["week": "2026-11-02"])) { error in
            guard case JournalAPIError.transport = error else { return XCTFail("got \(error)") }
        }
    }

    func testTimelineWeekProjectsSendsTheOffsetAndLimit() async throws {
        let (api, recorder) = makeStubbedAPI(body: ["week": "2026-11-02", "total": 0, "offset": 24,
                                                     "next_offset": NSNull(), "projects": []])
        _ = try await api.timelineWeekProjects("2026-11-02", offset: 24, limit: 24)
        let url = try XCTUnwrap(recorder.lastRequest?.url)
        XCTAssertEqual(url.path, "/timeline/weeks/2026-11-02/projects")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "offset" }?.value, "24")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "24")
    }

    func testTimelineWeekProjects404IsNotFound() async {
        let (api, _) = makeStubbedAPI(status: 404, body: ["error": "not_found"])
        do { _ = try await api.timelineWeekProjects("2026-11-02", offset: 0, limit: 24); XCTFail("expected a throw") }
        catch { XCTAssertEqual(error as? JournalAPIError, .notFound) }
    }
}
