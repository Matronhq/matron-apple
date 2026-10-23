import XCTest
import Foundation
import MatronModels
@testable import MatronJournal

/// Counts `onRevoked` calls and drives the monitor's clock.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var _fires = 0
    private var _now = ContinuousClock.now
    var fires: Int { lock.withLock { _fires } }
    var now: ContinuousClock.Instant { lock.withLock { _now } }
    func fire() { lock.withLock { _fires += 1 } }
    func advance(_ by: Duration) { lock.withLock { _now += by } }
}

final class CredentialRevocationMonitorTests: XCTestCase {
    private func makeMonitor(_ probe: Probe, threshold: Int = 3,
                             span: Duration = .seconds(10)) -> CredentialRevocationMonitor {
        CredentialRevocationMonitor(rejectionThreshold: threshold, minimumSpan: span,
                                    now: { probe.now }, onRevoked: { probe.fire() })
    }

    // MARK: Handshake

    func testHandshakeRejectionFiresAtOnce() {
        let probe = Probe()
        let monitor = makeMonitor(probe)
        monitor.handle(.rejected)
        XCTAssertEqual(probe.fires, 1)
        XCTAssertTrue(monitor.hasFired)
    }

    func testRepeatedRejectionsFireOnlyOnce() {
        let probe = Probe()
        let monitor = makeMonitor(probe)
        monitor.handle(.rejected)
        monitor.handle(.rejected)
        for _ in 0..<5 {
            probe.advance(.seconds(10))
            monitor.noteResponse(status: 401)
        }
        XCTAssertEqual(probe.fires, 1)
    }

    func testConcurrentRejectionsFireOnlyOnce() async {
        let probe = Probe()
        let monitor = makeMonitor(probe)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { monitor.handle(.rejected) }
            }
        }
        XCTAssertEqual(probe.fires, 1)
    }

    func testCancelledMonitorNeverFires() {
        let probe = Probe()
        let monitor = makeMonitor(probe)
        monitor.cancel()
        monitor.handle(.rejected)
        XCTAssertEqual(probe.fires, 0)
        XCTAssertFalse(monitor.hasFired)
    }

    // MARK: REST

    func testA401ThatKeepsComingFires() {
        let probe = Probe()
        let monitor = makeMonitor(probe)
        monitor.noteResponse(status: 401)
        probe.advance(.seconds(5))
        monitor.noteResponse(status: 401)
        XCTAssertEqual(probe.fires, 0)
        probe.advance(.seconds(5))
        monitor.noteResponse(status: 401)
        XCTAssertEqual(probe.fires, 1)
    }

    func testASingle401DoesNotFire() {
        let probe = Probe()
        let monitor = makeMonitor(probe)
        monitor.noteResponse(status: 401)
        probe.advance(.seconds(60))
        XCTAssertEqual(probe.fires, 0)
    }

    /// A burst of parallel requests all 401ing within a moment (one blip)
    /// is not "keeps returning 401".
    func testABurstOf401sWithinTheSpanDoesNotFire() {
        let probe = Probe()
        let monitor = makeMonitor(probe)
        for _ in 0..<10 { monitor.noteResponse(status: 401) }
        XCTAssertEqual(probe.fires, 0)
        probe.advance(.seconds(10))
        monitor.noteResponse(status: 401)
        XCTAssertEqual(probe.fires, 1, "still rejected after the span: now it is a revoke")
    }

    func testASuccessInBetweenResetsTheCount() {
        let probe = Probe()
        let monitor = makeMonitor(probe)
        monitor.noteResponse(status: 401)
        probe.advance(.seconds(6))
        monitor.noteResponse(status: 401)
        monitor.noteResponse(status: 200)
        probe.advance(.seconds(6))
        monitor.noteResponse(status: 401)
        XCTAssertEqual(probe.fires, 0)
    }

    func testAnAcceptedHandshakeResetsTheCount() {
        let probe = Probe()
        let monitor = makeMonitor(probe)
        monitor.noteResponse(status: 401)
        probe.advance(.seconds(6))
        monitor.noteResponse(status: 401)
        monitor.handle(.accepted)
        probe.advance(.seconds(6))
        monitor.noteResponse(status: 401)
        XCTAssertEqual(probe.fires, 0)
    }

    func test403NeverSignsOut() {
        let probe = Probe()
        let monitor = makeMonitor(probe)
        for _ in 0..<10 {
            monitor.noteResponse(status: 403)
            probe.advance(.seconds(10))
        }
        XCTAssertEqual(probe.fires, 0)
    }

    /// A 403 is the server answering an authenticated device, so it also
    /// breaks a run of 401s.
    func test403ResetsTheCount() {
        let probe = Probe()
        let monitor = makeMonitor(probe)
        monitor.noteResponse(status: 401)
        probe.advance(.seconds(6))
        monitor.noteResponse(status: 401)
        monitor.noteResponse(status: 403)
        probe.advance(.seconds(6))
        monitor.noteResponse(status: 401)
        XCTAssertEqual(probe.fires, 0)
    }

    func testServerErrorsAndRateLimitsNeverSignOut() {
        let probe = Probe()
        let monitor = makeMonitor(probe)
        for status in [500, 502, 503, 504, 429, 500, 503] {
            monitor.noteResponse(status: status)
            probe.advance(.seconds(10))
        }
        XCTAssertEqual(probe.fires, 0)
    }

    // MARK: Wiring

    private func makeStubbedAPI(status: Int, token: String?, monitor: CredentialRevocationMonitor) -> JournalAPI {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = Data("{}".utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: token,
                          authResponses: { monitor.noteResponse(status: $0) })
    }

    func testAPIReportsTokenBearing401s() async {
        let probe = Probe()
        let monitor = makeMonitor(probe, threshold: 2, span: .zero)
        let api = makeStubbedAPI(status: 401, token: "t", monitor: monitor)
        _ = try? await api.snapshot()
        _ = try? await api.snapshot()
        XCTAssertEqual(probe.fires, 1)
    }

    func testAWrongPasswordInSecuritySettingsIsNotARevokedToken() async {
        // 401 `bad_password` from a `/2fa` route: the token was accepted and
        // only the password typed to confirm the change was wrong.
        let probe = Probe()
        let monitor = makeMonitor(probe, threshold: 1, span: .zero)
        let api = makeStubbedAPI(status: 401, token: "t", monitor: monitor)
        ItemsStubURLProtocol.body = Data(#"{"error":"bad_password"}"#.utf8)
        _ = try? await api.disableTwoFactor(password: "wrong", code: "123456")
        _ = try? await api.disableTwoFactor(password: "wrong", code: "123456")
        XCTAssertEqual(probe.fires, 0)
    }

    func testAPIDoesNotReportRequestsWithoutAToken() async {
        let probe = Probe()
        let monitor = makeMonitor(probe, threshold: 1, span: .zero)
        let api = makeStubbedAPI(status: 401, token: nil, monitor: monitor)
        _ = try? await api.snapshot()
        XCTAssertEqual(probe.fires, 0)
    }

    func testAPIDoesNotReportTransportFailures() async {
        let probe = Probe()
        let monitor = makeMonitor(probe, threshold: 1, span: .zero)
        let api = JournalAPI(serverURL: URL(string: "http://127.0.0.1:1")!, token: "t",
                             authResponses: { monitor.noteResponse(status: $0) })
        _ = try? await api.snapshot()
        XCTAssertEqual(probe.fires, 0)
    }

    private func seededEngine(connector: FakeConnector, monitor: CredentialRevocationMonitor) throws -> JournalSyncEngine {
        let store = try makeTestStore(.memory)
        try store.applyColdSnapshot([ConvoSummaryDTO(id: "c1", title: "", sessionState: "running",
                                                     lastSeq: 0, snippet: "", createdAt: 0)], headSeq: 0)
        return JournalSyncEngine(api: JournalAPI(serverURL: URL(string: "https://chat.example.com")!),
                                 store: store, connector: connector, token: "t", ownSender: "user:alice",
                                 search: nil, backoffBaseSeconds: 0.01,
                                 credentialSignals: { monitor.handle($0) })
    }

    func testEngineReportsARefusedHandshake() async throws {
        let probe = Probe()
        let monitor = makeMonitor(probe)
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"error","code":"auth"}"#)
        let engine = try seededEngine(connector: FakeConnector([socket]), monitor: monitor)
        await engine.beginSync()
        for _ in 0..<200 where probe.fires == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(probe.fires, 1)
        await engine.endSync()
    }

    /// A plain network failure keeps the engine retrying and says nothing
    /// about the credentials.
    func testEngineDoesNotReportNetworkFailures() async throws {
        let probe = Probe()
        let monitor = makeMonitor(probe, threshold: 1, span: .zero)
        let connector = FakeConnector([])
        connector.connectError = JournalConnectionError.socketClosed
        let engine = try seededEngine(connector: connector, monitor: monitor)
        await engine.beginSync()
        for _ in 0..<100 where connector.connectCount < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(connector.connectCount, 2)
        XCTAssertEqual(probe.fires, 0)
        await engine.endSync()
    }

    func testEngineReportsAnAcceptedHandshake() async throws {
        let probe = Probe()
        let monitor = makeMonitor(probe, threshold: 2, span: .zero)
        monitor.noteResponse(status: 401)
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":0}"#)
        let engine = try seededEngine(connector: FakeConnector([socket]), monitor: monitor)
        await engine.beginSync()
        try await engine.waitUntilReady()
        // The accepted hello cleared the earlier 401, so one more is not a
        // run of two.
        monitor.noteResponse(status: 401)
        XCTAssertEqual(probe.fires, 0)
        await engine.endSync()
    }
}
