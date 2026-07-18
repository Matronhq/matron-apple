import XCTest
@testable import MatronJournal

final class RelayClientTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func test_mapCreate_parses201() throws {
        let r = try RelayClient.mapCreate(status: 201, data: data(
            #"{"rid":"23456789BCDFGHJKMNPQRSTVWX","secret":"\#(String(repeating: "a", count: 64))","expires_in":180}"#))
        XCTAssertEqual(r, Rendezvous(rid: "23456789BCDFGHJKMNPQRSTVWX",
                                     secret: String(repeating: "a", count: 64), expiresIn: 180))
    }

    func test_mapCreate_errors() {
        XCTAssertThrowsError(try RelayClient.mapCreate(status: 429, data: data(#"{"status":429,"reason":"rate_limited"}"#))) {
            XCTAssertEqual($0 as? RelayError, .rateLimited)
        }
        XCTAssertThrowsError(try RelayClient.mapCreate(status: 201, data: data(#"{"nope":true}"#))) {
            XCTAssertEqual($0 as? RelayError, .transport("malformed relay response"))
        }
        XCTAssertThrowsError(try RelayClient.mapCreate(status: 500, data: Data())) {
            XCTAssertEqual($0 as? RelayError, .transport("HTTP 500"))
        }
    }

    func test_mapPoll_coversAllStates() throws {
        XCTAssertEqual(try RelayClient.mapPoll(status: 204, data: Data()), .waiting)
        XCTAssertEqual(try RelayClient.mapPoll(status: 200, data: data(#"{"server":"https://j.example.com","code":"2345-6789"}"#)),
                       .offered(server: "https://j.example.com", code: "2345-6789"))
        XCTAssertThrowsError(try RelayClient.mapPoll(status: 404, data: Data())) { XCTAssertEqual($0 as? RelayError, .notFound) }
        XCTAssertThrowsError(try RelayClient.mapPoll(status: 403, data: Data())) { XCTAssertEqual($0 as? RelayError, .forbidden) }
        XCTAssertThrowsError(try RelayClient.mapPoll(status: 429, data: Data())) { XCTAssertEqual($0 as? RelayError, .rateLimited) }
        XCTAssertThrowsError(try RelayClient.mapPoll(status: 200, data: data(#"{"server":"https://x"}"#))) {
            XCTAssertEqual($0 as? RelayError, .transport("malformed relay response"))
        }
    }

    func test_mapOffer_coversAllStates() throws {
        XCTAssertNoThrow(try RelayClient.mapOffer(status: 204))
        XCTAssertThrowsError(try RelayClient.mapOffer(status: 409)) { XCTAssertEqual($0 as? RelayError, .conflict) }
        XCTAssertThrowsError(try RelayClient.mapOffer(status: 404)) { XCTAssertEqual($0 as? RelayError, .notFound) }
        XCTAssertThrowsError(try RelayClient.mapOffer(status: 429)) { XCTAssertEqual($0 as? RelayError, .rateLimited) }
        XCTAssertThrowsError(try RelayClient.mapOffer(status: 400)) { XCTAssertEqual($0 as? RelayError, .transport("HTTP 400")) }
    }

    func test_requestBuilders_hitTheDocumentedPathsAndBodies() throws {
        let base = URL(string: "https://push.matron.chat")!
        let create = RelayClient.createRequest(baseURL: base)
        XCTAssertEqual(create.url?.absoluteString, "https://push.matron.chat/link/rendezvous")
        XCTAssertEqual(create.httpMethod, "POST")

        let poll = RelayClient.pollRequest(baseURL: base, rid: "RID", secret: "SEC")
        XCTAssertEqual(poll.url?.absoluteString, "https://push.matron.chat/link/rendezvous/RID?secret=SEC")
        XCTAssertEqual(poll.httpMethod, "GET")

        let offer = RelayClient.offerRequest(baseURL: base, rid: "RID", server: "https://j.example.com", code: "2345-6789")
        XCTAssertEqual(offer.url?.absoluteString, "https://push.matron.chat/link/rendezvous/RID/offer")
        XCTAssertEqual(offer.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: offer.httpBody ?? Data()) as? [String: String]
        XCTAssertEqual(body, ["server": "https://j.example.com", "code": "2345-6789"])
    }
}
