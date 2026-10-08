import XCTest
import MatronModels
@testable import MatronJournal

final class BriefingsAPITests: XCTestCase {
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

    private let latestBody: [String: Any] = [
        "briefing": ["id": "br_1", "body": "## Sweep\n- all quiet", "created_at": 1_800_000_000_000,
                     "convo_id": "c-coord", "seq": 4242],
        "refresh": ["requested_at": 1_800_000_100_000, "state": "pending", "expires_at": 1_800_000_700_000],
        "next_refresh_at": 1_800_000_700_000,
        "has_coordinator": true,
    ]

    func testLatestDecodesTheBriefingAndTheRefresh() async throws {
        let latest = try await makeStubbedAPI(status: 200, body: latestBody).latestBriefing()
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/briefings/latest") == true)
        XCTAssertEqual(latest.briefing, Briefing(id: "br_1", body: "## Sweep\n- all quiet",
                                                 createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                 convoID: "c-coord", seq: 4242))
        XCTAssertEqual(latest.refresh, BriefingRefresh(requestedAt: Date(timeIntervalSince1970: 1_800_000_100),
                                                       state: .pending,
                                                       expiresAt: Date(timeIntervalSince1970: 1_800_000_700)))
        XCTAssertEqual(latest.nextRefreshAt, Date(timeIntervalSince1970: 1_800_000_700))
        XCTAssertTrue(latest.hasCoordinator)
    }

    func testLatestWithNothingYet() async throws {
        let latest = try await makeStubbedAPI(status: 200, body: [
            "briefing": NSNull(), "refresh": NSNull(), "next_refresh_at": NSNull(), "has_coordinator": false,
        ]).latestBriefing()
        XCTAssertEqual(latest, LatestBriefing(briefing: nil, refresh: nil, nextRefreshAt: nil, hasCoordinator: false))
    }

    func testRefreshStatesDecode() {
        XCTAssertEqual(BriefingRefresh(json: ["requested_at": 1000, "state": "failed", "outcome": "offline"]),
                       BriefingRefresh(requestedAt: Date(timeIntervalSince1970: 1), state: .failed, outcome: "offline"))
        XCTAssertEqual(BriefingRefresh(json: ["requested_at": 1000, "state": "timed_out"])?.state, .timedOut)
        XCTAssertNil(BriefingRefresh(json: ["requested_at": 1000, "state": "dancing"]))
    }

    func testLatestOnAnOldJournalIsUnsupported() async {
        do {
            _ = try await makeStubbedAPI(status: 404, body: ["error": "not_found"]).latestBriefing()
            XCTFail("expected unsupported")
        } catch {
            XCTAssertEqual(error as? BriefingsError, .unsupported)
        }
    }

    func testRefreshPostsAndAccepts202() async throws {
        let latest = try await makeStubbedAPI(status: 202, body: latestBody).refreshBriefing()
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/briefings/refresh") == true)
        XCTAssertEqual(latest.refresh?.state, .pending)
    }

    func testRefreshTooSoonCarriesRetryAt() async {
        do {
            _ = try await makeStubbedAPI(status: 429, body: ["error": "rate_limited", "retry_at": 1_800_000_120_000])
                .refreshBriefing()
            XCTFail("expected rateLimited")
        } catch {
            XCTAssertEqual(error as? BriefingsError, .rateLimited(retryAt: Date(timeIntervalSince1970: 1_800_000_120)))
        }
    }

    func testRefreshRefusals() async {
        let cases: [(Int, [String: Any], BriefingsError)] = [
            (409, ["error": "conflict", "blocked_by": "no_coordinator"], .noCoordinator),
            (503, ["error": "busy"], .busy),
            (404, ["error": "not_found"], .unsupported),
        ]
        for (status, body, expected) in cases {
            do {
                _ = try await makeStubbedAPI(status: status, body: body).refreshBriefing()
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? BriefingsError, expected, "HTTP \(status)")
            }
        }
    }

    func testOtherStatusesKeepTheSharedMapping() async {
        do {
            _ = try await makeStubbedAPI(status: 401, body: ["error": "unauthenticated"]).latestBriefing()
            XCTFail("expected unauthenticated")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .unauthenticated)
        }
        do {
            _ = try await makeStubbedAPI(status: 200, body: ["briefing": NSNull()]).latestBriefing()
            XCTFail("expected a malformed response")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .transport("malformed briefings response"))
        }
    }

    // MARK: - Live frame

    func testDecodesBriefingFrame() {
        XCTAssertEqual(ServerFrame.decode(#"{"kind":"briefing","action":"published","briefing_id":"br_1"}"#),
                       .briefing(BriefingSignal(action: BriefingSignal.published, briefingID: "br_1")))
        XCTAssertEqual(ServerFrame.decode(#"{"kind":"briefing","action":"refreshing"}"#),
                       .briefing(BriefingSignal(action: BriefingSignal.refreshing)))
        // An action this build doesn't know still means "refetch".
        XCTAssertEqual(ServerFrame.decode(#"{"kind":"briefing","action":"archived"}"#),
                       .briefing(BriefingSignal(action: "archived")))
        XCTAssertNil(ServerFrame.decode(#"{"kind":"briefing"}"#))
    }
}
