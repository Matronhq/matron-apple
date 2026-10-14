import XCTest
import MatronModels
@testable import MatronJournal

final class RoutinesAPITests: XCTestCase {
    static let scheduledJSON: [String: Any] = [
        "id": "rt_0123456789abcdef", "user_id": "alice", "name": "daily-sweep", "title": "Daily sweep",
        "schedule": "5 7 * * *", "trigger": NSNull(), "tz": "Europe/London",
        "prompt": "Routine daily-sweep: follow the playbook.", "enabled": true, "origin": "seed",
        "next_at": 1_760_000_000_000, "last_fired_at": 1_759_900_000_000, "last_outcome": "applied now",
        "created_at": 1_759_000_000_000, "updated_at": 1_759_500_000_000,
    ]
    static let triggeredJSON: [String: Any] = [
        "id": "rt_fedcba9876543210", "name": "disk-low", "title": "Box disk under the threshold",
        "schedule": NSNull(), "trigger": ["kind": "disk_under", "pct": 20], "tz": "Europe/London",
        "prompt": "Routine disk-low.", "enabled": false, "origin": "seed", "next_at": NSNull(),
        "last_fired_at": NSNull(), "last_outcome": NSNull(),
        "created_at": 1_759_000_000_000, "updated_at": 1_759_000_000_000,
    ]

    private func makeStubbedAPI(status: Int, body: [String: Any]) -> JournalAPI {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: "t")
    }

    private var lastBodyJSON: [String: Any]? {
        ItemsStubURLProtocol.lastBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func testDecodeKeepsBothKindsAndDropsMalformedRows() throws {
        var both = Self.scheduledJSON
        both["trigger"] = ["kind": "stalled", "reset_minutes": 120]
        let routines = try JournalAPI.decodeRoutines(["routines": [
            Self.scheduledJSON, Self.triggeredJSON, ["id": "rt_broken"], both,
            ["id": "rt_x", "name": "odd", "title": "Odd", "prompt": "p", "trigger": ["kind": "moon_phase"],
             "created_at": 1, "updated_at": 1],
        ]])
        XCTAssertEqual(routines.map(\.name), ["daily-sweep", "disk-low"])
        let scheduled = routines[0], triggered = routines[1]
        XCTAssertEqual(scheduled.schedule, "5 7 * * *")
        XCTAssertNil(scheduled.trigger)
        XCTAssertTrue(scheduled.enabled)
        XCTAssertEqual(scheduled.nextAt, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(scheduled.lastOutcome, "applied now")
        XCTAssertEqual(triggered.trigger, .diskUnder(pct: 20))
        XCTAssertFalse(triggered.enabled)
        XCTAssertNil(triggered.nextAt)
        XCTAssertThrowsError(try JournalAPI.decodeRoutines([:]))
    }

    func testListGetsTheCollection() async throws {
        let api = makeStubbedAPI(status: 200, body: ["routines": [Self.scheduledJSON]])
        let routines = try await api.listRoutines()
        XCTAssertEqual(routines.count, 1)
        let request = try XCTUnwrap(ItemsStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/routines")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testListOnAnOlderJournalIsUnsupported() async {
        let api = makeStubbedAPI(status: 404, body: ["error": "not_found"])
        do { _ = try await api.listRoutines(); XCTFail("expected a throw") } catch {
            XCTAssertEqual(error as? RoutinesError, .unsupported)
        }
    }

    func testCreateScheduledSendsNameScheduleAndZone() async throws {
        let api = makeStubbedAPI(status: 201, body: ["routine": Self.scheduledJSON])
        _ = try await api.createRoutine(name: "daily-sweep", draft: RoutineDraft(
            title: " Daily sweep ", prompt: "Do it.\n", tz: "Europe/London", schedule: "5  7 * * *", enabled: true))
        let request = try XCTUnwrap(ItemsStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/routines")
        let body = try XCTUnwrap(lastBodyJSON)
        XCTAssertEqual(body["name"] as? String, "daily-sweep")
        XCTAssertEqual(body["title"] as? String, "Daily sweep")
        XCTAssertEqual(body["prompt"] as? String, "Do it.")
        XCTAssertEqual(body["schedule"] as? String, "5 7 * * *")
        XCTAssertEqual(body["tz"] as? String, "Europe/London")
        XCTAssertEqual(body["enabled"] as? Bool, true)
        XCTAssertNil(body["trigger"])
        XCTAssertNil(body["convo_id"], "a client never names a conversation")
    }

    func testCreateTriggeredSendsTheTriggerAndNoSchedule() async throws {
        let api = makeStubbedAPI(status: 201, body: ["routine": Self.triggeredJSON])
        _ = try await api.createRoutine(name: "disk-low", draft: RoutineDraft(
            title: "Disk", prompt: "Look.", tz: "Europe/London", trigger: .stalled(resetMinutes: 90)))
        let body = try XCTUnwrap(lastBodyJSON)
        XCTAssertNil(body["schedule"])
        let trigger = try XCTUnwrap(body["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["kind"] as? String, "stalled")
        XCTAssertEqual(trigger["reset_minutes"] as? Int, 90)
    }

    func testCreateConflictsSayWhichOne() async {
        let cases: [(Int, [String: Any], RoutinesError)] = [
            (409, ["error": "conflict", "blocked_by": "name"], .nameTaken),
            (409, ["error": "conflict", "blocked_by": "cap"], .tooMany),
            (400, ["error": "bad_request"], .rejected),
        ]
        for (status, body, expected) in cases {
            let api = makeStubbedAPI(status: status, body: body)
            do {
                _ = try await api.createRoutine(name: "x", draft: RoutineDraft(title: "t", prompt: "p", tz: "UTC", schedule: "0 9 * * *"))
                XCTFail("expected a throw for \(status)")
            } catch {
                XCTAssertEqual(error as? RoutinesError, expected)
            }
        }
    }

    func testPauseIsAPatchOfEnabledAlone() async throws {
        let api = makeStubbedAPI(status: 200, body: ["routine": Self.triggeredJSON])
        let routine = try await api.setRoutineEnabled(id: "rt_fedcba9876543210", enabled: false)
        XCTAssertFalse(routine.enabled)
        let request = try XCTUnwrap(ItemsStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/routines/rt_fedcba9876543210")
        let body = try XCTUnwrap(lastBodyJSON)
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body["enabled"] as? Bool, false)
    }

    func testEditOfAMissingRoutineIsNotFound() async {
        let api = makeStubbedAPI(status: 404, body: ["error": "not_found"])
        do {
            _ = try await api.updateRoutine(id: "rt_gone", draft: RoutineDraft(title: "t", prompt: "p", tz: "UTC"))
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? RoutinesError, .notFound)
        }
    }

    func testDeleteAndRun() async throws {
        var api = makeStubbedAPI(status: 200, body: ["ok": true])
        try await api.deleteRoutine(id: "rt_1")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.url?.path, "/routines/rt_1")

        api = makeStubbedAPI(status: 202, body: ["accepted": true])
        let accepted = try await api.runRoutine(id: "rt_1")
        XCTAssertEqual(accepted, .accepted)
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.url?.path, "/routines/rt_1/run")

        api = makeStubbedAPI(status: 202, body: ["delivered": false, "reason": "no_coordinator"])
        let refused = try await api.runRoutine(id: "rt_1")
        XCTAssertEqual(refused, .notDelivered(reason: "no_coordinator"))
        XCTAssertEqual(refused.message, "Not sent: there is no Coordinator to run it.")
    }
}
