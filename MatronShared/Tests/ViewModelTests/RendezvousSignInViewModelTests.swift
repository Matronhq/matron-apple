import XCTest
import MatronAuth
import MatronJournal
import MatronModels
@testable import MatronViewModels

@MainActor
final class RendezvousSignInViewModelTests: XCTestCase {
    private static let rid1 = "23456789BCDFGHJKMNPQRSTVWX"
    private static let rid2 = "X".padding(toLength: 26, withPad: "X", startingAt: 0)

    // MARK: Fakes

    private final class FakeRelay: RelayRendezvousing, @unchecked Sendable {
        var createResults: [Result<Rendezvous, Error>] =
            [.success(Rendezvous(rid: rid1, secret: String(repeating: "a", count: 64), expiresIn: 180))]
        private(set) var createCount = 0
        var pollScript: [Result<RendezvousPollResult, Error>] = [.success(.waiting)]
        private(set) var pollCount = 0
        var holdPoll = false
        private var pollContinuations: [CheckedContinuation<Void, Never>] = []
        var pollGateReached = false
        func releasePoll() { pollContinuations.forEach { $0.resume() }; pollContinuations.removeAll() }

        func createRendezvous() async throws -> Rendezvous {
            createCount += 1
            return try (createResults.count > 1 ? createResults.removeFirst() : createResults[0]).get()
        }
        func pollRendezvous(rid: String, secret: String) async throws -> RendezvousPollResult {
            pollCount += 1
            if holdPoll {
                pollGateReached = true
                await withCheckedContinuation { pollContinuations.append($0) }
            }
            return try (pollScript.count > 1 ? pollScript.removeFirst() : pollScript[0]).get()
        }
        func offerRendezvous(rid: String, server: String, code: String) async throws {}
    }

    private final class FakeClaimer: LinkClaiming, @unchecked Sendable {
        var claimResult: Result<LinkClaim, Error> = .success(LinkClaim(claimToken: "ct", expiresIn: 120))
        var pollScript: [Result<LinkPollResult, Error>] = []
        private(set) var claimedCodes: [String] = []
        func linkClaim(code: String, deviceName: String) async throws -> LinkClaim {
            claimedCodes.append(code)
            return try claimResult.get()
        }
        func linkPoll(claimToken: String) async throws -> LinkPollResult {
            try (pollScript.count > 1 ? pollScript.removeFirst() : pollScript[0]).get()
        }
    }

    // Verbatim copy of LinkSignInViewModelTests.swift's file-private FakeAuth.
    private final class FakeAuth: AuthService, @unchecked Sendable {
        var persistedSessions: [UserSession] = []
        var persistError: Error?
        func probe(_ rawURL: String) async throws -> ServerCapabilities {
            ServerCapabilities(supportsPasswordLogin: true, supportsSSO: false)
        }
        func loginPassword(homeserverURL: URL, username: String, password: String,
                           initialDeviceDisplayName: String) async throws -> UserSession {
            fatalError("unused")
        }
        func restoreSession() async throws -> UserSession? { nil }
        func persist(_ session: UserSession) throws {
            if let persistError { throw persistError }
            persistedSessions.append(session)
        }
        func clearSession() throws {}
    }

    // Same helper convention as LinkSignInViewModelTests.swift.
    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeVM(relay: FakeRelay, claimer: FakeClaimer,
                        auth: FakeAuth = FakeAuth())
        -> (RendezvousSignInViewModel, LinkSignInViewModel, FakeAuth) {
        let link = LinkSignInViewModel(auth: auth, deviceDisplayName: "Matron Mac",
                                       apiFactory: { _ in claimer },
                                       pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        let vm = RendezvousSignInViewModel(relay: relay, link: link,
                                           pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        return (vm, link, auth)
    }

    // MARK: Tests

    func test_start_showsRlinkQR_thenOfferDrivesLinkSignInToCompletion() async throws {
        let relay = FakeRelay()
        relay.pollScript = [.success(.waiting),
                            .success(.offered(server: "https://chat.example.com", code: "2345-6789"))]
        let claimer = FakeClaimer()
        claimer.pollScript = [.success(.approved(LinkApproval(token: "tok99", deviceID: 42, userID: 7, username: "dan")))]
        let (vm, link, auth) = makeVM(relay: relay, claimer: claimer)

        await vm.start()
        XCTAssertEqual(vm.phase, .showing(qrPayload: "matron://rlink?v=1&rid=\(Self.rid1)"))

        let expected = UserSession(userID: "dan", deviceID: "42",
                                   homeserverURL: URL(string: "https://chat.example.com")!, accessToken: "tok99")
        await waitUntil(link.phase == .signedIn(expected))
        XCTAssertEqual(link.phase, .signedIn(expected))
        XCTAssertEqual(vm.phase, .connecting(serverHost: "chat.example.com"))
        XCTAssertEqual(claimer.claimedCodes, ["2345-6789"])
        XCTAssertEqual(auth.persistedSessions.count, 1)
    }

    func test_expiredRendezvous_silentlyRegenerates() async {
        let relay = FakeRelay()
        relay.createResults = [
            .success(Rendezvous(rid: Self.rid1, secret: String(repeating: "a", count: 64), expiresIn: 180)),
            .success(Rendezvous(rid: Self.rid2, secret: String(repeating: "b", count: 64), expiresIn: 180)),
        ]
        relay.pollScript = [.failure(RelayError.notFound), .success(.waiting)]
        let (vm, _, _) = makeVM(relay: relay, claimer: FakeClaimer())
        await vm.start()
        await waitUntil(relay.createCount == 2)
        await waitUntil(vm.phase == .showing(qrPayload: "matron://rlink?v=1&rid=\(Self.rid2)"))
        XCTAssertEqual(vm.phase, .showing(qrPayload: "matron://rlink?v=1&rid=\(Self.rid2)"))
    }

    func test_createFailure_isARetryableError() async {
        let relay = FakeRelay()
        relay.createResults = [.failure(RelayError.transport("down"))]
        let (vm, _, _) = makeVM(relay: relay, claimer: FakeClaimer())
        await vm.start()
        XCTAssertEqual(vm.phase, .error("Couldn't reach the Matron relay — check your connection and try again."))
    }

    func test_transientPollFailure_keepsPolling() async {
        let relay = FakeRelay()
        relay.pollScript = [.failure(RelayError.transport("blip")), .success(.waiting), .success(.waiting)]
        let (vm, _, _) = makeVM(relay: relay, claimer: FakeClaimer())
        await vm.start()
        await waitUntil(relay.pollCount >= 3)
        XCTAssertEqual(vm.phase, .showing(qrPayload: "matron://rlink?v=1&rid=\(Self.rid1)"))
    }

    func test_stop_whilePollInFlight_dropsTheLateOffer() async {
        let relay = FakeRelay()
        relay.holdPoll = true
        relay.pollScript = [.success(.offered(server: "https://chat.example.com", code: "2345-6789"))]
        let claimer = FakeClaimer()
        let (vm, link, auth) = makeVM(relay: relay, claimer: claimer)
        await vm.start()
        await waitUntil(relay.pollGateReached)
        vm.stop()
        relay.releasePoll()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(link.phase, .idle)
        XCTAssertTrue(claimer.claimedCodes.isEmpty)
        XCTAssertTrue(auth.persistedSessions.isEmpty)
    }
}
