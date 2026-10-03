import XCTest
@testable import MatronJournal

final class TTSAPITests: XCTestCase {
    private func makeAPI() -> JournalAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: "t")
    }

    private func bodyJSON() -> [String: Any]? {
        StubURLProtocol.lastRequestBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func testVoicesDecode() async throws {
        StubURLProtocol.responses = ["/tts/voices": (200, #"""
        {"voices":[{"id":"en-GB-Harry","name":"Harry","locale":"en-GB","gender":"male"},
                   {"id":"en-GB-Emily","name":"Emily","locale":"en-GB","gender":"female"},
                   {"name":"no id"}],
         "default":"en-GB-Harry"}
        """#)]
        let voices = try await makeAPI().ttsVoices()
        XCTAssertEqual(voices.voices.map(\.id), ["en-GB-Harry", "en-GB-Emily"])
        XCTAssertEqual(voices.voices.first?.name, "Harry")
        XCTAssertEqual(voices.defaultVoiceID, "en-GB-Harry")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    /// An old journal (404) and one with no key (501) both mean "use the
    /// on-device voice"; anything else is a failure to ask again later.
    func testVoicesUnavailableAndFailed() async {
        for (status, body) in [(404, #"{"error":"not_found"}"#), (501, #"{"error":"tts_unconfigured"}"#)] {
            StubURLProtocol.responses = ["/tts/voices": (status, body)]
            do {
                _ = try await makeAPI().ttsVoices()
                XCTFail("expected a throw for \(status)")
            } catch {
                XCTAssertEqual(error as? TTSError, .unavailable, "\(status)")
            }
        }
        StubURLProtocol.responses = ["/tts/voices": (503, #"{"error":"tts_busy"}"#)]
        do {
            _ = try await makeAPI().ttsVoices()
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? TTSError, .failed(status: 503, code: "tts_busy"))
        }
    }

    func testClipPostsTextAndVoiceAndReturnsTheBytes() async throws {
        StubURLProtocol.responses = ["/tts": (200, "ID3-audio-bytes")]
        let audio = try await makeAPI().tts(text: "The deploy finished.", voice: "en-GB-Emily")
        XCTAssertEqual(audio, Data("ID3-audio-bytes".utf8))
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(bodyJSON()?["text"] as? String, "The deploy finished.")
        XCTAssertEqual(bodyJSON()?["voice"] as? String, "en-GB-Emily")
        XCTAssertNil(bodyJSON()?["format"], "the journal's default (mp3) is what the phone plays")
    }

    func testClipOmitsAnUnchosenVoiceAndCutsLongText() async throws {
        StubURLProtocol.responses = ["/tts": (200, "x")]
        _ = try await makeAPI().tts(text: String(repeating: "a", count: 2_500), voice: nil)
        XCTAssertNil(bodyJSON()?["voice"])
        XCTAssertEqual((bodyJSON()?["text"] as? String)?.count, 2_000)
    }

    /// Every answer that is not a clip is one error the player falls back
    /// on: the status and the journal's code ride along for the log.
    func testEveryNonClipAnswerIsAFailure() async {
        let cases: [(Int, String, String?)] = [
            (400, #"{"error":"bad_request"}"#, "bad_request"),
            (400, #"{"error":"unknown_voice"}"#, "unknown_voice"), (403, #"{"error":"forbidden"}"#, "forbidden"),
            (404, #"{"error":"not_found"}"#, "not_found"), (413, "", nil),
            (429, #"{"error":"tts_budget_exceeded"}"#, "tts_budget_exceeded"),
            (501, #"{"error":"tts_unconfigured"}"#, "tts_unconfigured"), (502, #"{"error":"tts_failed"}"#, "tts_failed"),
            (503, #"{"error":"tts_busy"}"#, "tts_busy"), (200, "", nil),
        ]
        for (status, body, code) in cases {
            StubURLProtocol.responses = ["/tts": (status, body)]
            do {
                _ = try await makeAPI().tts(text: "hi", voice: nil)
                XCTFail("expected a throw for \(status)")
            } catch {
                XCTAssertEqual(error as? TTSError, .failed(status: status, code: code), "\(status)")
            }
        }
    }
}
