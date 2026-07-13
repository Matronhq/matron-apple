import XCTest
import MatronEvents
@testable import MatronDesignSystem

/// Plain logic tests (not snapshots) for the live-output widget's
/// engine — parser state across chunks and the session's replay dedupe.
final class AnsiSGRParserTests: XCTestCase {
    func testPlainTextPassesThrough() {
        var parser = AnsiSGRParser()
        let out = parser.append("hello world\n")
        XCTAssertEqual(String(out.characters), "hello world\n")
    }

    func testColorAndReset() {
        var parser = AnsiSGRParser()
        let out = parser.append("\u{1B}[31mred\u{1B}[0m plain")
        XCTAssertEqual(String(out.characters), "red plain")
        let runs = out.runs.map { (String(out[$0.range].characters), $0.foregroundColor) }
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].0, "red")
        XCTAssertEqual(runs[0].1, AnsiSGRParser.palette[1])
        XCTAssertNil(runs[1].1)
    }

    func testStateCarriesAcrossChunks() {
        var parser = AnsiSGRParser()
        _ = parser.append("\u{1B}[32m")
        let out = parser.append("green")
        let run = out.runs.first
        XCTAssertEqual(run?.foregroundColor, AnsiSGRParser.palette[2])
    }

    func testEscapeSplitAcrossChunksDoesNotLeak() {
        var parser = AnsiSGRParser()
        // Chunk boundary mid-sequence: "ESC[3" ... "1mred"
        let first = parser.append("a\u{1B}[3")
        XCTAssertEqual(String(first.characters), "a")
        let second = parser.append("1mred")
        XCTAssertEqual(String(second.characters), "red")
        XCTAssertEqual(second.runs.first?.foregroundColor, AnsiSGRParser.palette[1])
    }

    func testNonSGRSequencesAreStripped() {
        var parser = AnsiSGRParser()
        // Cursor-up CSI, OSC window title, and a two-byte escape.
        let out = parser.append("\u{1B}[2Aup\u{1B}]0;title\u{07}osc\u{1B}Mtwo")
        XCTAssertEqual(String(out.characters), "uposctwo")
    }

    func testBoldOnOff() {
        var parser = AnsiSGRParser()
        let out = parser.append("\u{1B}[1mbold\u{1B}[22mnormal")
        let runs = out.runs.map { (String(out[$0.range].characters), $0.inlinePresentationIntent) }
        XCTAssertEqual(runs[0].0, "bold")
        XCTAssertEqual(runs[0].1, .stronglyEmphasized)
        XCTAssertEqual(runs[1].0, "normal")
        XCTAssertNil(runs[1].1)
    }

    func test256ColorMapping() {
        XCTAssertEqual(AnsiSGRParser.color256(1), AnsiSGRParser.palette[1])
        XCTAssertNotNil(AnsiSGRParser.color256(120)) // cube
        XCTAssertNotNil(AnsiSGRParser.color256(240)) // grayscale
        XCTAssertNil(AnsiSGRParser.color256(300))
    }
}

@MainActor
final class LiveOutputSessionTests: XCTestCase {
    private func event(expiresAt: Date? = nil) -> LiveOutputEvent {
        LiveOutputEvent(
            toolUseID: "toolu_1", command: "npm test",
            viewerURL: URL(string: "https://viewer.example.com/live?token=t")!,
            expiresAt: expiresAt)
    }

    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testStreamsAndCompletes() async {
        let session = LiveOutputSession(event: event()) { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.data(chunk: "line one\n"))
                continuation.yield(.data(chunk: "line two\n"))
                continuation.yield(.complete(exitCode: 0, denied: false, truncated: false))
                continuation.finish()
            }
        }
        session.startIfNeeded()
        await waitUntil { session.phase == .complete(exitCode: 0, denied: false, truncated: false) }
        XCTAssertEqual(String(session.output.characters), "line one\nline two\n")
        XCTAssertTrue(session.hasOutput)
    }

    func testReconnectReplayIsDeduped() async {
        // First connection delivers 2 chunks then dies; the retry replays
        // from offset 0 (viewer semantics) plus new output. Rendered text
        // must not duplicate the replayed prefix.
        let connections = Counter()
        let session = LiveOutputSession(event: event()) { _ in
            AsyncThrowingStream { continuation in
                Task {
                    if await connections.next() == 1 {
                        continuation.yield(.data(chunk: "AAAA"))
                        continuation.yield(.data(chunk: "BBBB"))
                        continuation.finish(throwing: URLError(.networkConnectionLost))
                    } else {
                        continuation.yield(.data(chunk: "AAAABBBB"))
                        continuation.yield(.data(chunk: "CCCC"))
                        continuation.yield(.complete(exitCode: 0, denied: false, truncated: false))
                        continuation.finish()
                    }
                }
            }
        }
        session.startIfNeeded()
        await waitUntil(8) {
            if case .complete = session.phase { return true }
            return false
        }
        XCTAssertEqual(String(session.output.characters), "AAAABBBBCCCC")
    }

    func testExpiredEventNeverConnects() async {
        let session = LiveOutputSession(event: event(expiresAt: Date(timeIntervalSinceNow: -10))) { _ in
            XCTFail("must not connect for an expired token")
            return AsyncThrowingStream { $0.finish() }
        }
        session.startIfNeeded()
        XCTAssertEqual(session.phase, .expired)
    }

    func testDeniedCompletion() async {
        let session = LiveOutputSession(event: event()) { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.complete(exitCode: nil, denied: true, truncated: false))
                continuation.finish()
            }
        }
        session.startIfNeeded()
        await waitUntil { session.phase == .complete(exitCode: nil, denied: true, truncated: false) }
        XCTAssertFalse(session.hasOutput)
    }

    func testHugeOutputIsTrimmedToRollingTail() async {
        // The tee allows logs up to 50MB; the pane keeps a bounded rolling
        // tail so a giant replay can't balloon memory or hang rendering.
        let big = String(repeating: "x", count: 150_000) + String(repeating: "y", count: 100_000)
        let session = LiveOutputSession(event: event()) { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.data(chunk: big))
                continuation.yield(.complete(exitCode: 0, denied: false, truncated: true))
                continuation.finish()
            }
        }
        session.startIfNeeded()
        await waitUntil(8) {
            if case .complete = session.phase { return true }
            return false
        }
        let text = String(session.output.characters)
        XCTAssertLessThanOrEqual(text.count, 200_000)
        XCTAssertTrue(text.hasSuffix("y"), "trim must drop the HEAD, keeping the newest output")
    }

    func testStoreReusesAndEvicts() {
        let store = LiveOutputSessionStore(limit: 2)
        let a = store.session(for: event())
        let aAgain = store.session(for: event())
        XCTAssertTrue(a === aAgain, "same tool_use_id must reuse the session")

        let b = LiveOutputEvent(toolUseID: "b", command: "ls",
                                viewerURL: a.event.viewerURL, expiresAt: nil)
        let c = LiveOutputEvent(toolUseID: "c", command: "ls",
                                viewerURL: a.event.viewerURL, expiresAt: nil)
        _ = store.session(for: b)
        _ = store.session(for: c) // evicts "toolu_1"
        let aNew = store.session(for: event())
        XCTAssertFalse(a === aNew, "evicted session must not be resurrected")
    }
}

private actor Counter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}
