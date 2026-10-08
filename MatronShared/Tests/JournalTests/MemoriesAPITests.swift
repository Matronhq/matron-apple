import XCTest
import MatronModels
@testable import MatronJournal

final class MemoriesAPITests: XCTestCase {
    /// Same stub as `MissionsAPITests` (`ItemsStubURLProtocol`, defined in
    /// `ItemsAPITests.swift`).
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

    func testDecodeMemoriesDropsMalformedRowsButKeepsTheRest() throws {
        let memories = try JournalAPI.decodeMemories(["memories": [MemoryModelTests.memoryJSON, ["id": "me_broken"]]])
        XCTAssertEqual(memories.map(\.name), ["avoid-atlas-and-birch"])
    }

    func testDecodeMemoriesWithoutAnArrayIsAnError() {
        XCTAssertThrowsError(try JournalAPI.decodeMemories([:]))
        XCTAssertEqual(try JournalAPI.decodeMemories(["memories": []]), [])
    }

    func testListGetsTheCollectionWithTheBearer() async throws {
        let api = makeStubbedAPI(status: 200, body: ["memories": [MemoryModelTests.memoryJSON]])
        let memories = try await api.listMemories()
        XCTAssertEqual(memories.count, 1)
        let request = try XCTUnwrap(ItemsStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/memories")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    /// An older journal has no route: the collection 404 is "unsupported",
    /// not an error the screen should banner.
    func testListOnAnOlderJournalIsUnsupported() async {
        let api = makeStubbedAPI(status: 404, body: ["error": "not_found"])
        do {
            _ = try await api.listMemories()
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? MemoriesError, .unsupported)
        }
    }

    func testSavePutsTheWholeMemoryAndAcceptsCreated() async throws {
        let api = makeStubbedAPI(status: 201, body: ["memory": MemoryModelTests.memoryJSON])
        let saved = try await api.saveMemory(name: "avoid-atlas-and-birch", description: "Never.", body: "", type: .feedback)
        XCTAssertEqual(saved.name, "avoid-atlas-and-birch")
        let request = try XCTUnwrap(ItemsStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/memories/avoid-atlas-and-birch")
        let body = try XCTUnwrap(lastBodyJSON)
        XCTAssertEqual(body["description"] as? String, "Never.")
        // Always sent, even empty: an omitted body CLEARS the stored one.
        XCTAssertEqual(body["body"] as? String, "")
        XCTAssertEqual(body["type"] as? String, "feedback")
        // A client never sends convo_id (the journal answers 400).
        XCTAssertNil(body["convo_id"])
    }

    func testSaveAcceptsUpdated() async throws {
        let api = makeStubbedAPI(status: 200, body: ["memory": MemoryModelTests.memoryJSON])
        let saved = try await api.saveMemory(name: "avoid-atlas-and-birch", description: "Never.", body: "b", type: .user)
        XCTAssertEqual(saved.id, "me_0123456789abcdef")
    }

    func testSaveErrorsMapToTheScreensWords() async {
        let cases: [(Int, [String: Any], MemoriesError)] = [
            (409, ["error": "too_many"], .tooMany),
            (400, ["error": "bad_request"], .rejected("")),
            (404, ["error": "not_found"], .unsupported),
        ]
        for (status, body, expected) in cases {
            let api = makeStubbedAPI(status: status, body: body)
            do {
                _ = try await api.saveMemory(name: "a", description: "d", body: "", type: .feedback)
                XCTFail("expected a throw for \(status)")
            } catch {
                XCTAssertEqual(error as? MemoriesError, expected, "status \(status)")
            }
        }
        XCTAssertEqual(MemoriesError.tooMany.localizedDescription,
                       "You already have 200 memories, the most the journal keeps. Delete one first.")
    }

    func testDeleteSendsDeleteAndMapsA404ToGone() async throws {
        var api = makeStubbedAPI(status: 200, body: ["memory": MemoryModelTests.memoryJSON])
        let deleted = try await api.deleteMemory(name: "avoid-atlas-and-birch")
        XCTAssertEqual(deleted.name, "avoid-atlas-and-birch")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.url?.path, "/memories/avoid-atlas-and-birch")

        api = makeStubbedAPI(status: 404, body: ["error": "not_found"])
        do {
            try await api.deleteMemory(name: "gone")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? MemoriesError, .notFound)
        }
    }
}
