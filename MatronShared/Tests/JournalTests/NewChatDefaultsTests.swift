import XCTest
@testable import MatronJournal

/// The `/defaults` contract (journal `GET`/`PUT /defaults`): the answer's
/// shape, the `PUT` bodies, and the errors the store reads.
final class NewChatDefaultsTests: XCTestCase {
    private func makeStubbedAPI(status: Int = 200,
                                body: [String: Any] = ["default_model": "opus[1m]", "default_effort": NSNull()]) -> JournalAPI {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: "t")
    }

    private func sentBody() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as? [String: Any])
    }

    func testGetDecodesBothKeys() async throws {
        let defaults = try await makeStubbedAPI().newChatDefaults()
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/defaults") == true)
        XCTAssertEqual(defaults, NewChatDefaults(model: "opus[1m]", effort: nil))
    }

    func testDecodeReadsMissingNullAndEmptyAsBoxDefault() {
        XCTAssertEqual(NewChatDefaults.decode([:]), NewChatDefaults())
        XCTAssertEqual(NewChatDefaults.decode(["default_model": "", "default_effort": NSNull()]), NewChatDefaults())
        XCTAssertEqual(NewChatDefaults.decode(["default_model": "claude-opus-5-5", "default_effort": "max"]),
                       NewChatDefaults(model: "claude-opus-5-5", effort: "max"))
        XCTAssertNil(NewChatDefaults.decode(["default_model": "opus", "default_effort": 3]),
                     "a non-string value rejects the whole body, never half-applies")
    }

    func testMalformedAnswerIsATransportError() async {
        do {
            _ = try await makeStubbedAPI(body: ["default_model": ["opus"]]).newChatDefaults()
            XCTFail("expected a transport error")
        } catch {
            guard case .transport = error as? JournalAPIError else { return XCTFail("got \(error)") }
        }
    }

    func testOldJournalIsNotFound() async {
        do {
            _ = try await makeStubbedAPI(status: 404, body: ["error": "not_found"]).newChatDefaults()
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .notFound)
        }
    }

    func testPutSendsOnlyTheKeyChanged() async throws {
        let api = makeStubbedAPI(body: ["default_model": "sonnet", "default_effort": "high"])

        let stored = try await api.setNewChatDefault(.model, to: "sonnet")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "PUT")
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/defaults") == true)
        XCTAssertEqual(try sentBody() as NSDictionary, ["default_model": "sonnet"])
        XCTAssertEqual(stored, NewChatDefaults(model: "sonnet", effort: "high"))

        _ = try await api.setNewChatDefault(.effort, to: nil)
        XCTAssertEqual(try sentBody() as NSDictionary, ["default_effort": NSNull()],
                       "Box default is an explicit null")
    }

    func testRefusedValueSurfacesTheJournalsCode() async {
        do {
            _ = try await makeStubbedAPI(status: 400, body: ["error": "bad_effort"]).setNewChatDefault(.effort, to: "loud")
            XCTFail("expected an http error")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .http(status: 400, message: "bad_effort"))
        }
    }
}
