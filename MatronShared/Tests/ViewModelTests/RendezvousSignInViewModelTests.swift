import XCTest
import MatronAuth
import MatronJournal
import MatronModels
@testable import MatronViewModels

@MainActor
final class RendezvousSignInViewModelTests: XCTestCase {
    private static let rid1 = "23456789BCDFGHJKMNPQRSTVWX"
    private static let rid2 = "X".padding(toLength: 26, withPad: "X", startingAt: 0)
    // The interop vector: key + a box that opens to {server, code} below.
    private static let vectorKeyB64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    private static let vectorKey = Base64URL.decode(vectorKeyB64)!
    private static let vectorBox = Base64URL.decode(
        "oKGio6SlpqeoqaqrnToPSDe9Z81AX6W7cw6wrUqDdnP61jZC-XZH6w_HEC-xGSrdgwAwUjv5JvIrSLDNcjZwf1rpOAMFFZLM4JJwtKZY9E-Fmmfg")!
    // vectorBox decrypts to server "https://chat.example.com", code "2345-6789".

    private final class FakeRelay: RelayRendezvousing, @unchecked Sendable {
        var createResults: [Result<Rendezvous, Error>] =
            [.success(Rendezvous(rid: rid1, secret: String(repeating: "a", count: 64), expiresIn: 180))]
        private(set) var createCount = 0
        var pollScript: [Result<RendezvousPollResult, Error>] = [.success(.waiting)]
        private(set) var pollCount = 0
        var holdPoll = false
        private var pollContinuations: [CheckedContinuation<Void, Never>] = []
        var pollGateReached = false
        private var bankedPollReleases = 0
        private let gateLock = NSLock()

        func releasePoll() {
            gateLock.lock()
            let toResume = pollContinuations
            pollContinuations.removeAll()
            if toResume.isEmpty { bankedPollReleases += 1 }
            gateLock.unlock()
            toResume.forEach { $0.resume() }
        }

        func createRendezvous() async throws -> Rendezvous {
            createCount += 1
            return try (createResults.count > 1 ? createResults.removeFirst() : createResults[0]).get()
        }
        func pollRendezvous(rid: String, secret: String) async throws -> RendezvousPollResult {
            pollCount += 1
            if holdPoll {
                pollGateReached = true
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    gateLock.lock()
                    if bankedPollReleases > 0 {
                        bankedPollReleases -= 1
                        gateLock.unlock()
                        c.resume()
                    } else {
                        pollContinuations.append(c)
                        gateLock.unlock()
                    }
                }
            }
            return try (pollScript.count > 1 ? pollScript.removeFirst() : pollScript[0]).get()
        }
        func offerRendezvous(rid: String, box: Data) async throws {}
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

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeVM(relay: FakeRelay, claimer: FakeClaimer,
                        auth: FakeAuth = FakeAuth(),
                        key: Data = vectorKey)
        -> (RendezvousSignInViewModel, LinkSignInViewModel, FakeAuth) {
        let link = LinkSignInViewModel(auth: auth, deviceDisplayName: "Matron Mac",
                                       apiFactory: { _ in claimer },
                                       pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        let vm = RendezvousSignInViewModel(relay: relay, link: link,
                                           pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1),
                                           keyProvider: { key })
        return (vm, link, auth)
    }

    func test_start_showsV2QR_thenOpensBoxAndDrivesLinkSignInToCompletion() async throws {
        let relay = FakeRelay()
        relay.pollScript = [.success(.waiting), .success(.offered(box: Self.vectorBox))]
        let claimer = FakeClaimer()
        claimer.pollScript = [.success(.approved(LinkApproval(token: "tok99", deviceID: 42, userID: 7, username: "dan")))]
        let (vm, link, auth) = makeVM(relay: relay, claimer: claimer)

        await vm.start()
        XCTAssertEqual(vm.phase, .showing(qrPayload: "matron://rlink?v=2&rid=\(Self.rid1)&k=\(Self.vectorKeyB64)"))

        let expected = UserSession(userID: "dan", deviceID: "42",
                                   homeserverURL: URL(string: "https://chat.example.com")!, accessToken: "tok99")
        await waitUntil(link.phase == .signedIn(expected))
        XCTAssertEqual(link.phase, .signedIn(expected))
        XCTAssertEqual(vm.phase, .connecting(serverHost: "chat.example.com"))
        XCTAssertEqual(claimer.claimedCodes, ["2345-6789"])
        XCTAssertEqual(auth.persistedSessions.count, 1)
    }

    func test_undecryptableBox_silentlyRegenerates() async {
        let relay = FakeRelay()
        relay.createResults = [
            .success(Rendezvous(rid: Self.rid1, secret: String(repeating: "a", count: 64), expiresIn: 180)),
            .success(Rendezvous(rid: Self.rid2, secret: String(repeating: "b", count: 64), expiresIn: 180)),
        ]
        // First poll returns a box this VM's key cannot open → treat like expiry.
        relay.pollScript = [.success(.offered(box: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05]))), .success(.waiting)]
        let (vm, _, _) = makeVM(relay: relay, claimer: FakeClaimer())
        await vm.start()
        await waitUntil(relay.createCount == 2)
        await waitUntil(vm.phase == .showing(qrPayload: "matron://rlink?v=2&rid=\(Self.rid2)&k=\(Self.vectorKeyB64)"))
        XCTAssertEqual(vm.phase, .showing(qrPayload: "matron://rlink?v=2&rid=\(Self.rid2)&k=\(Self.vectorKeyB64)"))
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
        await waitUntil(vm.phase == .showing(qrPayload: "matron://rlink?v=2&rid=\(Self.rid2)&k=\(Self.vectorKeyB64)"))
        XCTAssertEqual(vm.phase, .showing(qrPayload: "matron://rlink?v=2&rid=\(Self.rid2)&k=\(Self.vectorKeyB64)"))
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
        XCTAssertEqual(vm.phase, .showing(qrPayload: "matron://rlink?v=2&rid=\(Self.rid1)&k=\(Self.vectorKeyB64)"))
    }

    func test_connecting_whenLinkClaimFails_becomesError() async {
        let relay = FakeRelay()
        relay.pollScript = [.success(.offered(box: Self.vectorBox))]
        let claimer = FakeClaimer()
        claimer.claimResult = .failure(JournalAPIError.notFound)
        let (vm, link, _) = makeVM(relay: relay, claimer: claimer)
        await vm.start()
        await waitUntil(vm.phase == .error("Couldn't connect to that computer's session — try again."))
        XCTAssertEqual(vm.phase, .error("Couldn't connect to that computer's session — try again."))
        XCTAssertEqual(link.phase, .error("Code not recognized or expired. Show a fresh QR code and try again."))
    }

    func test_stop_whilePollInFlight_dropsTheLateOffer() async {
        let relay = FakeRelay()
        relay.holdPoll = true
        relay.pollScript = [.success(.offered(box: Self.vectorBox))]
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

    func test_offerWhileManualClaimInFlight_isDeferredUntilClaimResolves() async {
        let relay = FakeRelay()
        relay.pollScript = [.success(.offered(box: Self.vectorBox))]
        let claimer = FakeClaimer()
        claimer.pollScript = [.success(.pending)]
        let (vm, link, _) = makeVM(relay: relay, claimer: claimer)

        link.serverURL = "https://typed.example.com"
        link.codeInput = "1111-2222"
        await link.submitManual()
        XCTAssertEqual(link.phase, .waitingForApproval)

        await vm.start()
        try? await Task.sleep(for: .milliseconds(50))
        if case .connecting = vm.phase {
            XCTFail("offer must not hijack an in-flight manual claim")
        }
        XCTAssertEqual(link.serverURL, "https://typed.example.com",
                       "the user's typed server must not be overwritten mid-claim")
        XCTAssertEqual(link.codeInput, "1111-2222")

        // The manual claim resolves (denied → .error): a later poll re-fetches
        // the still-pending box and claims it (the decrypted offer).
        claimer.pollScript = [.success(.denied)]
        await waitUntil(link.serverURL == "https://chat.example.com")
        XCTAssertEqual(link.serverURL, "https://chat.example.com",
                       "deferred offer must be claimed once the link VM comes back to rest")
        XCTAssertEqual(link.codeInput, "2345-6789")
        vm.stop()
        link.cancel()
    }
}
