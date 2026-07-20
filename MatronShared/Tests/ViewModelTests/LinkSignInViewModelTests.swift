import XCTest
@testable import MatronViewModels
@testable import MatronJournal
@testable import MatronAuth
import MatronModels

private final class FakeLinkClaimer: LinkClaiming, @unchecked Sendable {
    var claimResult: Result<LinkClaim, Error> = .success(LinkClaim(claimToken: "aa11", expiresIn: 60))
    /// Consumed one per poll; last repeats when dry.
    var pollScript: [Result<LinkPollResult, Error>] = [.success(.pending)]
    /// Deterministic alternative to real-time sleeps for interleaving
    /// tests: when set, `linkPoll()` suspends (after recording the call)
    /// until the test calls `releasePoll()`. Real-time delays make
    /// interleavings a coin flip on loaded CI runners; a gate guarantees
    /// them (same pattern as `FakeDeviceLinker.holdStatus` in
    /// DeviceLinkViewModelTests).
    var holdPoll = false
    private var pollContinuations: [CheckedContinuation<Void, Never>] = []
    /// Same gated pattern as `holdPoll`, for `linkClaim()` — needed to
    /// deterministically land a `cancel()` inside a claim's `linkClaim()`
    /// await so the post-await generation re-check can be exercised.
    var holdClaim = false
    private var claimContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var claimedCodes: [String] = []
    private(set) var claimedDeviceNames: [String] = []
    private(set) var pollCount = 0

    func releasePoll() {
        pollContinuations.forEach { $0.resume() }
        pollContinuations.removeAll()
    }

    func releaseClaim() {
        claimContinuations.forEach { $0.resume() }
        claimContinuations.removeAll()
    }

    func linkClaim(code: String, deviceName: String) async throws -> LinkClaim {
        claimedCodes.append(code)
        claimedDeviceNames.append(deviceName)
        if holdClaim {
            await withCheckedContinuation { claimContinuations.append($0) }
        }
        return try claimResult.get()
    }
    func linkPoll(claimToken: String) async throws -> LinkPollResult {
        pollCount += 1
        if holdPoll {
            await withCheckedContinuation { pollContinuations.append($0) }
        }
        let result = pollScript.count > 1 ? pollScript.removeFirst() : pollScript[0]
        return try result.get()
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

@MainActor
final class LinkSignInViewModelTests: XCTestCase {
    private func makeVM(_ fake: FakeLinkClaimer, auth: FakeAuth = FakeAuth()) -> (LinkSignInViewModel, FakeAuth) {
        let vm = LinkSignInViewModel(auth: auth, deviceDisplayName: "Matron iOS",
                                     apiFactory: { _ in fake },
                                     pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        return (vm, auth)
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isSignedIn(_ vm: LinkSignInViewModel) -> Bool {
        if case .signedIn = vm.phase { return true }
        return false
    }

    func test_scanned_happyPath_buildsAndPersistsSession() async {
        let fake = FakeLinkClaimer()
        fake.pollScript = [.success(.pending),
                           .success(.approved(LinkApproval(token: "tok99", deviceID: 42, userID: 7, username: "dan")))]
        let (vm, auth) = makeVM(fake)
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fchat.example.com&code=KTNM-3VQ8")
        await waitUntil(self.isSignedIn(vm))
        let expected = UserSession(userID: "dan", deviceID: "42",
                                   homeserverURL: URL(string: "https://chat.example.com")!,
                                   accessToken: "tok99")
        XCTAssertEqual(vm.phase, .signedIn(expected))
        XCTAssertEqual(auth.persistedSessions, [expected]) // persisted BEFORE phase flips
        XCTAssertEqual(fake.claimedCodes, ["KTNM-3VQ8"])
        XCTAssertEqual(fake.claimedDeviceNames, ["Matron iOS"]) // same name password login sends
    }

    func test_scanned_notALink_and_wrongVersion() async {
        let (vm, _) = makeVM(FakeLinkClaimer())
        await vm.handleScanned("https://a-random-website.example/qr")
        XCTAssertEqual(vm.phase, .error("Not a Matron sign-in code."))
        await vm.handleScanned("matron://link?v=2&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")
        XCTAssertEqual(vm.phase, .error("This QR code needs a newer version of Matron."))
    }

    func test_manual_happyPath_normalizesCodeAndURL() async {
        let fake = FakeLinkClaimer()
        fake.pollScript = [.success(.approved(LinkApproval(token: "tok99", deviceID: 42, userID: 7, username: "dan")))]
        let (vm, _) = makeVM(fake)
        vm.serverURL = "chat.example.com" // ServerURLValidator adds https://
        vm.codeInput = "ktnm3vq8"
        XCTAssertEqual(vm.codeInput, "KTNM-3VQ8") // auto-format like PairingViewModel
        await vm.submitManual()
        await waitUntil(self.isSignedIn(vm))
        XCTAssertEqual(fake.claimedCodes, ["KTNM-3VQ8"])
        guard case .signedIn(let session) = vm.phase else { return XCTFail("\(vm.phase)") }
        XCTAssertEqual(session.homeserverURL.absoluteString, "https://chat.example.com")
    }

    func test_manual_pastedLinkURI_claimsAgainstEmbeddedServer() async {
        let fake = FakeLinkClaimer()
        fake.pollScript = [.success(.approved(LinkApproval(token: "tok99", deviceID: 42, userID: 7, username: "dan")))]
        let (vm, _) = makeVM(fake)
        vm.codeInput = "matron://link?v=1&server=https%3A%2F%2Fchat.example.com&code=KTNM-3VQ8"
        // The XXXX-XXXX auto-formatter must not mangle a pasted link.
        XCTAssertEqual(vm.codeInput, "matron://link?v=1&server=https%3A%2F%2Fchat.example.com&code=KTNM-3VQ8")
        XCTAssertTrue(vm.codeInputIsFullLink)
        await vm.submitManual() // serverURL field never touched
        await waitUntil(self.isSignedIn(vm))
        XCTAssertEqual(fake.claimedCodes, ["KTNM-3VQ8"])
        guard case .signedIn(let session) = vm.phase else { return XCTFail("\(vm.phase)") }
        XCTAssertEqual(session.homeserverURL.absoluteString, "https://chat.example.com")
    }

    func test_manual_pastedLinkURI_overridesTypedServer_andSurvivesWhitespace() async {
        let fake = FakeLinkClaimer()
        fake.pollScript = [.success(.approved(LinkApproval(token: "tok99", deviceID: 42, userID: 7, username: "dan")))]
        let (vm, _) = makeVM(fake)
        vm.serverURL = "typed.example.org"
        vm.codeInput = " matron://link?v=1&server=https%3A%2F%2Fchat.example.com&code=KTNM-3VQ8\n"
        XCTAssertTrue(vm.codeInputIsFullLink)
        await vm.submitManual()
        await waitUntil(self.isSignedIn(vm))
        guard case .signedIn(let session) = vm.phase else { return XCTFail("\(vm.phase)") }
        XCTAssertEqual(session.homeserverURL.absoluteString, "https://chat.example.com")
    }

    func test_manual_pastedLinkURI_wrongVersion_and_malformed() async {
        let (vm, _) = makeVM(FakeLinkClaimer())
        vm.codeInput = "matron://link?v=2&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8"
        await vm.submitManual()
        XCTAssertEqual(vm.phase, .error("This link needs a newer version of Matron."))
        vm.codeInput = "matron://link?v=1&code=KTNM-3VQ8" // no server
        await vm.submitManual()
        XCTAssertEqual(vm.phase, .error("That doesn't look like a Matron sign-in link."))
    }

    func test_manual_bareCode_isNotAFullLink() async {
        let (vm, _) = makeVM(FakeLinkClaimer())
        vm.codeInput = "ktnm3vq8"
        XCTAssertFalse(vm.codeInputIsFullLink)
        XCTAssertEqual(vm.codeInput, "KTNM-3VQ8") // formatter still applies
    }

    func test_manual_invalidURL_errors() async {
        let (vm, _) = makeVM(FakeLinkClaimer())
        vm.serverURL = "not a url"
        vm.codeInput = "KTNM-3VQ8"
        await vm.submitManual()
        XCTAssertEqual(vm.phase, .error("That doesn't look like a valid server URL."))
    }

    func test_claim_conflict_notFound_rateLimited() async {
        for (error, message) in [
            (JournalAPIError.conflict, "This code was already used. Generate a new one on your signed-in device."),
            (JournalAPIError.notFound, "Code not recognized or expired. Show a fresh QR code and try again."),
            (JournalAPIError.rateLimited, "Too many attempts — try again in a minute."),
        ] {
            let fake = FakeLinkClaimer()
            fake.claimResult = .failure(error)
            let (vm, _) = makeVM(fake)
            await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")
            XCTAssertEqual(vm.phase, .error(message))
        }
    }

    func test_poll_denied() async {
        let fake = FakeLinkClaimer()
        fake.pollScript = [.success(.denied)]
        let (vm, _) = makeVM(fake)
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")
        await waitUntil(vm.phase == .error("Sign-in was denied on the other device."))
        XCTAssertEqual(vm.phase, .error("Sign-in was denied on the other device."))
    }

    func test_poll_expired() async {
        let fake = FakeLinkClaimer()
        fake.pollScript = [.failure(JournalAPIError.notFound)]
        let (vm, _) = makeVM(fake)
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")
        await waitUntil(vm.phase == .error("Sign-in expired. Scan again."))
        XCTAssertEqual(vm.phase, .error("Sign-in expired. Scan again."))
    }

    func test_poll_transportError_backsOffAndKeepsPolling() async {
        let fake = FakeLinkClaimer()
        fake.pollScript = [.failure(JournalAPIError.transport("offline")),
                           .success(.approved(LinkApproval(token: "t", deviceID: 1, userID: 1, username: "dan")))]
        let (vm, _) = makeVM(fake)
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")
        await waitUntil(self.isSignedIn(vm))
        XCTAssertTrue(isSignedIn(vm)) // one dropped poll never kills the flow
    }

    func test_cancel_stopsPollingAndReturnsToIdle() async {
        // Gated instead of raced against wall-clock sleeps: the original
        // "wait for one poll, cancel(), sleep 50ms, assert no growth"
        // version flaked under load, because cancel() only sets a
        // cancellation flag — it doesn't wait for an already-in-flight
        // linkPoll() call to notice. Holding that call open makes the
        // interleaving explicit: cancel() fires while the FIRST call is
        // provably still suspended, so releasing it and observing no
        // SECOND call is a deterministic check that the loop respects
        // cancellation before it re-polls (same pattern as
        // `FakeDeviceLinker.holdStatus` / `test_stop_haltsPolling` in
        // DeviceLinkViewModelTests).
        let fake = FakeLinkClaimer()
        fake.holdPoll = true
        let (vm, _) = makeVM(fake)
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")
        await waitUntil(fake.pollCount >= 1)
        vm.cancel()
        XCTAssertEqual(vm.phase, .idle)
        let count = fake.pollCount
        fake.releasePoll()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.pollCount, count)
    }

    func test_cancel_whilePollInFlight_doesNotPersistOrSignIn() async {
        // Finding 2 (security): a linkPoll() call already in flight when
        // cancel() runs can resolve LATE with .approved and then persist a
        // session the user cancelled + flip to .signedIn. Gated (held+
        // released) so the interleaving is exact: the poll is provably
        // parked in flight when cancel() lands, then released to prove the
        // loop abandons (generation bumped by cancel()) before persist and
        // before any phase write.
        let fake = FakeLinkClaimer()
        fake.holdPoll = true
        fake.pollScript = [.success(.approved(LinkApproval(token: "tok99", deviceID: 42, userID: 7, username: "dan")))]
        let (vm, auth) = makeVM(fake)
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fchat.example.com&code=KTNM-3VQ8")
        await waitUntil(fake.pollCount >= 1)   // linkPoll parked in flight
        vm.cancel()
        XCTAssertEqual(vm.phase, .idle)
        fake.releasePoll()                     // the in-flight poll resolves late with .approved
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.phase, .idle)        // must NOT flip to .signedIn
        XCTAssertTrue(auth.persistedSessions.isEmpty) // must NOT persist a cancelled session
    }

    func test_cancel_whileClaimInFlight_doesNotStartPollingOrPersist() async {
        // Finding 2 (residual): a linkClaim() in flight when cancel() lands
        // — reachable via onDisappear when password sign-in completes
        // concurrently — must not resume into .waitingForApproval +
        // startPolling(). startPolling() snapshots the ALREADY-BUMPED
        // generation, so the poll-loop guard can't catch it; only a
        // post-claim-await generation re-check in claim() does. Gated
        // (held+released) so the interleaving is exact.
        let fake = FakeLinkClaimer()
        fake.holdClaim = true
        let (vm, auth) = makeVM(fake)
        let scanTask = Task { await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fchat.example.com&code=KTNM-3VQ8") }
        await waitUntil(fake.claimedCodes.count >= 1)  // linkClaim parked in flight
        vm.cancel()
        XCTAssertEqual(vm.phase, .idle)
        fake.releaseClaim()                            // claim resolves late with success
        await scanTask.value
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.phase, .idle)                // must NOT flip to .waitingForApproval
        XCTAssertEqual(fake.pollCount, 0)              // no orphan poll started
        XCTAssertTrue(auth.persistedSessions.isEmpty)  // nothing persisted
    }

    func test_claim_whileSignedIn_doesNotRestartStateMachine() async {
        // Finding 3: a second scan/manual submit while already .signedIn
        // must not restart claim → poll and overwrite the signed-in state.
        let fake = FakeLinkClaimer()
        fake.pollScript = [.success(.approved(LinkApproval(token: "tok99", deviceID: 42, userID: 7, username: "dan")))]
        let (vm, _) = makeVM(fake)
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fchat.example.com&code=KTNM-3VQ8")
        await waitUntil(self.isSignedIn(vm))
        guard case .signedIn(let session) = vm.phase else { return XCTFail("\(vm.phase)") }
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fchat.example.com&code=WXYZ-2345")
        XCTAssertEqual(vm.phase, .signedIn(session)) // unchanged
        XCTAssertEqual(fake.claimedCodes, ["KTNM-3VQ8"]) // no second claim
    }

    func test_persistFailure_surfacesError() async {
        let fake = FakeLinkClaimer()
        fake.pollScript = [.success(.approved(LinkApproval(token: "t", deviceID: 1, userID: 1, username: "dan")))]
        let auth = FakeAuth()
        auth.persistError = NSError(domain: "disk", code: 1)
        let (vm, _) = makeVM(fake, auth: auth)
        await vm.handleScanned("matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")
        await waitUntil({ if case .error = vm.phase { return true }; return false }())
        XCTAssertEqual(vm.phase, .error("Signed in, but couldn't save the session — try again."))
    }
}
