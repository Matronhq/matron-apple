import XCTest
@testable import MatronJournal

final class RelayClientTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func test_mapCreate_parses201() throws {
        let r = try RelayClient.mapCreate(status: 201, data: data(
            #"{"rid":"23456789BCDFGHJKMNPQRSTVWX","secret":"\#(String(repeating: "a", count: 64))","expires_in":180}"#))
        XCTAssertEqual(r, Rendezvous(rid: "23456789BCDFGHJKMNPQRSTVWX",
                                     secret: String(repeating: "a", count: 64),
                                     expiresIn: 180))
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

    func test_offerRequest_postsBase64urlBox() throws {
        let box = Data([0x01, 0x02, 0x03, 0x04])
        let request = RelayClient.offerRequest(baseURL: MatronRelay.baseURL, rid: "R", box: box)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["box"] as? String, Base64URL.encode(box))
        XCTAssertEqual(obj.count, 1)
    }

    func test_mapPoll_204isWaiting_200decodesBox() throws {
        XCTAssertEqual(try RelayClient.mapPoll(status: 204, data: Data()), .waiting)
        let box = Data([0xaa, 0xbb, 0xcc])
        let json = try JSONSerialization.data(withJSONObject: ["box": Base64URL.encode(box)])
        XCTAssertEqual(try RelayClient.mapPoll(status: 200, data: json), .offered(box: box))
    }

    func test_mapPoll_undecodableBox_isTransportError() {
        let json = try! JSONSerialization.data(withJSONObject: ["box": "!!!not-base64!!!"])
        XCTAssertThrowsError(try RelayClient.mapPoll(status: 200, data: json))
    }

    func test_mapPoll_errorStatuses() {
        XCTAssertThrowsError(try RelayClient.mapPoll(status: 404, data: Data())) { XCTAssertEqual($0 as? RelayError, .notFound) }
        XCTAssertThrowsError(try RelayClient.mapPoll(status: 403, data: Data())) { XCTAssertEqual($0 as? RelayError, .forbidden) }
        XCTAssertThrowsError(try RelayClient.mapPoll(status: 429, data: Data())) { XCTAssertEqual($0 as? RelayError, .rateLimited) }
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

        let box = Data([0x01, 0x02, 0x03])
        let offer = RelayClient.offerRequest(baseURL: base, rid: "RID", box: box)
        XCTAssertEqual(offer.url?.absoluteString, "https://push.matron.chat/link/rendezvous/RID/offer")
        XCTAssertEqual(offer.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: offer.httpBody ?? Data()) as? [String: String]
        XCTAssertEqual(body, ["box": Base64URL.encode(box)])
    }
}
