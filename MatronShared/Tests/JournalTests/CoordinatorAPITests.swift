import XCTest
@testable import MatronJournal

final class CoordinatorAPITests: XCTestCase {
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

    func testGetDecodesTheConvoOrNone() async throws {
        let set = try await makeStubbedAPI(status: 200, body: ["convo_id": "c9"]).coordinator()
        XCTAssertEqual(set, "c9")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/coordinator") == true)
        let none = try await makeStubbedAPI(status: 200, body: ["convo_id": NSNull()]).coordinator()
        XCTAssertNil(none)
    }

    func testPutSendsTheIdOrAnExplicitNull() async throws {
        let stored = try await makeStubbedAPI(status: 200, body: ["convo_id": "c9"]).setCoordinator("c9")
        XCTAssertEqual(stored, "c9")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "PUT")
        let sent = try JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as? [String: Any]
        XCTAssertEqual(sent?["convo_id"] as? String, "c9")

        _ = try await makeStubbedAPI(status: 200, body: ["convo_id": NSNull()]).setCoordinator(nil)
        let cleared = try JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as? [String: Any]
        XCTAssertTrue(cleared?["convo_id"] is NSNull, "clearing sends convo_id: null, not an empty body")
    }

    func testPutOfAConvoNotOwnedIsNotFound() async {
        do {
            _ = try await makeStubbedAPI(status: 404, body: ["error": "not_found"]).setCoordinator("c-else")
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .notFound)
        }
    }
}
