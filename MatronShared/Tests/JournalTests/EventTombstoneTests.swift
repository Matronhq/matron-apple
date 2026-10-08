import XCTest
@testable import MatronJournal

/// The tombstone rules, as a table. Both insert paths and both sweeps route
/// through this one function, so everything either side of the launch path
/// agrees about what an aged-out payload looks like.
final class EventTombstoneTests: XCTestCase {
    private let ts = Date(timeIntervalSince1970: 1_000_000)

    private func toolOutput(command: String = "make test", liveLog: Bool = true,
                            expired: Bool? = nil) -> [String: Any] {
        var p: [String: Any] = [
            "message_ref": "toolu_1", "command": command,
            "exit_code": 1, "denied": false, "truncated": false,
            "snippet": "output text", "blob_ref": "blob-1",
        ]
        if liveLog { p["live_log"] = true }
        if let expired { p["expired"] = expired }
        return p
    }

    private func diff() -> [String: Any] {
        ["file_path": "/w/Sources/A.swift", "display_path": "Sources/A.swift",
         "tool": "Edit", "added": 2, "removed": 1, "truncated": false, "new_file": false,
         "diff": "@@ -1 +1 @@\n-a\n+b", "snippet": "short form"]
    }

    // MARK: Nothing to do

    func testFreshToolOutputIsUntouched() {
        XCTAssertNil(EventTombstone.apply(to: toolOutput(), type: JournalEventType.toolOutput,
                                          ts: ts, now: ts.addingTimeInterval(3600)))
    }

    func testFreshDiffIsUntouched() {
        XCTAssertNil(EventTombstone.apply(to: diff(), type: JournalEventType.diff,
                                          ts: ts, now: ts.addingTimeInterval(25 * 3600)),
                     "a diff has no 24h rule — only the 30-day retention one")
    }

    func testOtherTypesAreNeverRewritten() {
        XCTAssertNil(EventTombstone.apply(to: ["body": "hi"], type: JournalEventType.text,
                                          ts: ts, now: ts.addingTimeInterval(400 * 24 * 3600)))
    }

    func testNonLiveLogToolOutputSurvivesThe24hRule() {
        XCTAssertNil(EventTombstone.apply(to: toolOutput(liveLog: false),
                                          type: JournalEventType.toolOutput,
                                          ts: ts, now: ts.addingTimeInterval(25 * 3600)),
                     "offloaded/legacy payloads keep their durable snippet until retention")
    }

    func testAlreadyExpiredRowReturnsNil() {
        // `liveLog: true` deliberately: with it false the 24 h branch would
        // never be entered and this would pass without exercising the
        // idempotence logic it claims to cover.
        var tombstoned = toolOutput(liveLog: true, expired: true)
        tombstoned.removeValue(forKey: "snippet")
        tombstoned.removeValue(forKey: "live_log")
        tombstoned["blob_ref"] = NSNull()
        XCTAssertNil(EventTombstone.apply(to: tombstoned, type: JournalEventType.toolOutput,
                                          ts: ts, now: ts.addingTimeInterval(25 * 3600)),
                     "a second sweep over the same row must do no work")
    }

    /// The gate above removes `live_log`, so a row still carrying it while
    /// flagged expired (a server tombstone that kept the key) must also be
    /// left alone rather than rewritten forever.
    func testExpiredRowThatStillCarriesLiveLogIsStrippedOnceThenLeftAlone() throws {
        let once = try XCTUnwrap(EventTombstone.apply(
            to: toolOutput(liveLog: true, expired: true), type: JournalEventType.toolOutput,
            ts: ts, now: ts.addingTimeInterval(25 * 3600)))
        XCTAssertNil(once["live_log"])
        XCTAssertNil(EventTombstone.apply(to: once, type: JournalEventType.toolOutput,
                                          ts: ts, now: ts.addingTimeInterval(26 * 3600)))
    }

    // MARK: The 24h tool-log rule

    func testStaleLiveLogLosesItsBodyAndGainsExpired() throws {
        let out = try XCTUnwrap(EventTombstone.apply(to: toolOutput(),
                                                     type: JournalEventType.toolOutput,
                                                     ts: ts, now: ts.addingTimeInterval(25 * 3600)))
        XCTAssertNil(out["snippet"])
        XCTAssertNil(out["live_log"])
        XCTAssertTrue(out["blob_ref"] is NSNull, "the shipped tombstone shape nulls the blob ref")
        XCTAssertEqual(out["expired"] as? Bool, true)
        XCTAssertEqual(out["command"] as? String, "make test", "what ran survives the 24h rule in full")
        XCTAssertEqual((out["exit_code"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(out["denied"] as? Bool, false)
        XCTAssertEqual(out["truncated"] as? Bool, false)
        XCTAssertEqual(out["message_ref"] as? String, "toolu_1")
    }

    func testThe24hRuleDoesNotTruncateALongCommand() throws {
        let long = String(repeating: "x", count: 500)
        let out = try XCTUnwrap(EventTombstone.apply(to: toolOutput(command: long),
                                                     type: JournalEventType.toolOutput,
                                                     ts: ts, now: ts.addingTimeInterval(25 * 3600)))
        XCTAssertEqual(out["command"] as? String, long)
    }

    func testApplyingTwiceIsIdempotent() throws {
        let once = try XCTUnwrap(EventTombstone.apply(to: toolOutput(),
                                                      type: JournalEventType.toolOutput,
                                                      ts: ts, now: ts.addingTimeInterval(25 * 3600)))
        XCTAssertNil(EventTombstone.apply(to: once, type: JournalEventType.toolOutput,
                                          ts: ts, now: ts.addingTimeInterval(26 * 3600)))
    }

    // MARK: The 30-day retention rule

    func testRetentionTruncatesTheCommandTo200CharactersPlusEllipsis() throws {
        let long = String(repeating: "x", count: 500)
        let out = try XCTUnwrap(EventTombstone.apply(to: toolOutput(command: long),
                                                     type: JournalEventType.toolOutput,
                                                     ts: ts, now: ts.addingTimeInterval(31 * 24 * 3600)))
        XCTAssertEqual(out["command"] as? String, String(repeating: "x", count: 200) + "…")
        XCTAssertNil(out["snippet"])
        XCTAssertNil(out["live_log"])
        XCTAssertEqual(out["expired"] as? Bool, true)
        XCTAssertEqual((out["exit_code"] as? NSNumber)?.intValue, 1)
    }

    func testRetentionLeavesAShortCommandAlone() throws {
        let out = try XCTUnwrap(EventTombstone.apply(to: toolOutput(),
                                                     type: JournalEventType.toolOutput,
                                                     ts: ts, now: ts.addingTimeInterval(31 * 24 * 3600)))
        XCTAssertEqual(out["command"] as? String, "make test")
    }

    /// A row tombstoned by the 24h rule keeps its full command; when it
    /// later crosses the retention window the sweep must still shorten it,
    /// so "already expired" cannot short-circuit retention.
    func testRetentionStillTruncatesARowThe24hRuleAlreadyTombstoned() throws {
        let long = String(repeating: "y", count: 300)
        let dayOld = try XCTUnwrap(EventTombstone.apply(to: toolOutput(command: long),
                                                        type: JournalEventType.toolOutput,
                                                        ts: ts, now: ts.addingTimeInterval(25 * 3600)))
        let aged = try XCTUnwrap(EventTombstone.apply(to: dayOld, type: JournalEventType.toolOutput,
                                                      ts: ts, now: ts.addingTimeInterval(31 * 24 * 3600)))
        XCTAssertEqual(aged["command"] as? String, String(repeating: "y", count: 200) + "…")
    }

    func testRetentionStripsADiffButKeepsEveryOtherKey() throws {
        let out = try XCTUnwrap(EventTombstone.apply(to: diff(), type: JournalEventType.diff,
                                                     ts: ts, now: ts.addingTimeInterval(31 * 24 * 3600)))
        XCTAssertNil(out["diff"])
        XCTAssertNil(out["snippet"])
        XCTAssertEqual(out["expired"] as? Bool, true)
        XCTAssertEqual(out["file_path"] as? String, "/w/Sources/A.swift")
        XCTAssertEqual(out["display_path"] as? String, "Sources/A.swift")
        XCTAssertEqual(out["tool"] as? String, "Edit")
        XCTAssertEqual((out["added"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((out["removed"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(out["new_file"] as? Bool, false)
    }

    func testRetentionOnADiffIsIdempotent() throws {
        let once = try XCTUnwrap(EventTombstone.apply(to: diff(), type: JournalEventType.diff,
                                                      ts: ts, now: ts.addingTimeInterval(31 * 24 * 3600)))
        XCTAssertNil(EventTombstone.apply(to: once, type: JournalEventType.diff,
                                          ts: ts, now: ts.addingTimeInterval(40 * 24 * 3600)))
    }

    func testConstantsAreTheOnesTheSpecFixed() {
        XCTAssertEqual(EventTombstone.toolLogTTL, 24 * 3600)
        XCTAssertEqual(EventTombstone.retentionWindow, 30 * 24 * 3600)
        XCTAssertEqual(EventTombstone.commandStubLength, 200)
    }
}
