import XCTest
@testable import MatronViewModels
@testable import MatronJournal

/// Scriptable show-side fake: `statusScript` is consumed one result per
/// poll; when it runs dry the last result repeats.
private final class FakeDeviceLinker: DeviceLinking, @unchecked Sendable {
    var startResults: [Result<LinkStart, Error>] = [.success(LinkStart(code: "KTNM-3VQ8", expiresIn: 120))]
    var statusScript: [Result<LinkStatus, Error>] = [.success(.waiting(expiresIn: 100))]
    var approveResult: Result<Void, Error> = .success(())
    var denyResult: Result<Void, Error> = .success(())
    /// Deterministic alternative to real-time sleeps for interleaving
    /// tests: when set, `linkStatus()` suspends (after recording the call)
    /// until the test calls `releaseStatus()`. Real-time delays make
    /// interleavings a coin flip on loaded CI runners; a gate guarantees
    /// them (same pattern as `FakeDevicesProvider.holdApprove` in
    /// PairingViewModelTests).
    var holdStatus = false
    private var statusContinuations: [CheckedContinuation<Void, Never>] = []
    private var bankedStatusReleases = 0

    /// The gate methods run off the main actor (this class is not actor-
    /// isolated), so a `releaseX()` can land in the window between the
    /// call-count increment and the continuation being parked. A release
    /// that finds nobody parked is BANKED and consumed by the next park —
    /// without this, that interleaving loses the wake-up and the test hangs
    /// at its 2 s `waitUntil` timeout (seen on loaded CI runners). The lock
    /// makes park-or-consume and resume-or-bank atomic.
    private let gateLock = NSLock()

    func releaseStatus() {
        gateLock.lock()
        let toResume = statusContinuations
        statusContinuations.removeAll()
        if toResume.isEmpty { bankedStatusReleases += 1 }
        gateLock.unlock()
        toResume.forEach { $0.resume() }
    }

    private func parkStatus() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            gateLock.lock()
            if bankedStatusReleases > 0 {
                bankedStatusReleases -= 1
                gateLock.unlock()
                c.resume()
            } else {
                statusContinuations.append(c)
                gateLock.unlock()
            }
        }
    }

    /// Same gated pattern as `holdStatus`, for `linkStart()` — needed to
    /// deterministically land inside a regenerate's `linkStart` await so a
    /// concurrent `stop()` can be interleaved at an exact point instead of
    /// raced against wall-clock sleeps.
    var holdStart = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var bankedStartReleases = 0

    func releaseStart() {
        gateLock.lock()
        let toResume = startContinuations
        startContinuations.removeAll()
        if toResume.isEmpty { bankedStartReleases += 1 }
        gateLock.unlock()
        toResume.forEach { $0.resume() }
    }

    private func parkStart() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            gateLock.lock()
            if bankedStartReleases > 0 {
                bankedStartReleases -= 1
                gateLock.unlock()
                c.resume()
            } else {
                startContinuations.append(c)
                gateLock.unlock()
            }
        }
    }

    private(set) var startCount = 0
    private(set) var statusCount = 0
    private(set) var approvedCodes: [String] = []
    private(set) var deniedCodes: [String] = []

    func linkStart() async throws -> LinkStart {
        startCount += 1
        if holdStart {
            await parkStart()
        }
        let result = startResults.count > 1 ? startResults.removeFirst() : startResults[0]
        return try result.get()
    }
    func linkStatus() async throws -> LinkStatus {
        statusCount += 1
        if holdStatus {
            await parkStatus()
        }
        let result = statusScript.count > 1 ? statusScript.removeFirst() : statusScript[0]
        return try result.get()
    }
    func linkApprove(code: String) async throws {
        approvedCodes.append(code)
        try approveResult.get()
    }
    func linkDeny(code: String) async throws {
        deniedCodes.append(code)
        try denyResult.get()
    }
}

@MainActor
final class DeviceLinkViewModelTests: XCTestCase {
    private func makeVM(_ fake: FakeDeviceLinker) -> DeviceLinkViewModel {
        DeviceLinkViewModel(api: fake, serverURL: URL(string: "https://chat.example.com")!,
                            pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func test_start_showsCodeAndQRPayload() async {
        let vm = makeVM(FakeDeviceLinker())
        await vm.start()
        XCTAssertEqual(vm.phase, .showing(code: "KTNM-3VQ8"))
        XCTAssertEqual(vm.qrPayload,
                       LinkURI.format(server: URL(string: "https://chat.example.com")!, code: "KTNM-3VQ8"))
        vm.stop()
    }

    func test_start_notFound_meansServerTooOld() async {
        let fake = FakeDeviceLinker()
        fake.startResults = [.failure(JournalAPIError.notFound)]
        let vm = makeVM(fake)
        await vm.start()
        XCTAssertEqual(vm.phase, .unsupported)
    }

    func test_claimedStatus_flipsToApproveCard() async {
        let fake = FakeDeviceLinker()
        fake.statusScript = [.success(.waiting(expiresIn: 100)),
                             .success(.claimed(deviceName: "Pixel 9", requesterIP: "198.51.100.7", expiresIn: 90))]
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(vm.phase == .claimed(deviceName: "Pixel 9", requesterIP: "198.51.100.7"))
        XCTAssertEqual(vm.phase, .claimed(deviceName: "Pixel 9", requesterIP: "198.51.100.7"))
        vm.stop()
    }

    func test_statusNotFound_regeneratesSilently() async {
        let fake = FakeDeviceLinker()
        fake.startResults = [.success(LinkStart(code: "KTNM-3VQ8", expiresIn: 120)),
                             .success(LinkStart(code: "WXYZ-2345", expiresIn: 120))]
        fake.statusScript = [.failure(JournalAPIError.notFound),
                             .success(.waiting(expiresIn: 100))]
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(vm.phase == .showing(code: "WXYZ-2345"))
        XCTAssertEqual(vm.phase, .showing(code: "WXYZ-2345"))
        XCTAssertEqual(fake.startCount, 2)
        XCTAssertNil(vm.noticeMessage) // expiry while waiting is routine, not an error
        vm.stop()
    }

    func test_approve_isTerminalAndStopsPolling() async {
        let fake = FakeDeviceLinker()
        fake.statusScript = [.success(.claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1", expiresIn: 90))]
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(vm.phase == .claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1"))
        await vm.approve()
        XCTAssertEqual(vm.phase, .approved)
        XCTAssertEqual(fake.approvedCodes, ["KTNM-3VQ8"])
        let countAtApprove = fake.statusCount
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.statusCount, countAtApprove) // poll loop stopped
    }

    func test_approve_expired_regeneratesWithNotice() async {
        let fake = FakeDeviceLinker()
        fake.statusScript = [.success(.claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1", expiresIn: 5))]
        fake.approveResult = .failure(JournalAPIError.notFound)
        fake.startResults = [.success(LinkStart(code: "KTNM-3VQ8", expiresIn: 120)),
                             .success(LinkStart(code: "WXYZ-2345", expiresIn: 120))]
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(vm.phase == .claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1"))
        await vm.approve()
        XCTAssertEqual(vm.phase, .showing(code: "WXYZ-2345"))
        XCTAssertEqual(vm.noticeMessage, "Code expired — showing a fresh one")
        vm.stop()
    }

    func test_deny_isTerminal() async {
        let fake = FakeDeviceLinker()
        fake.statusScript = [.success(.claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1", expiresIn: 90))]
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(vm.phase == .claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1"))
        await vm.deny()
        XCTAssertEqual(vm.phase, .denied)
        XCTAssertEqual(fake.deniedCodes, ["KTNM-3VQ8"])
    }

    func test_stop_haltsPolling() async {
        // Gated instead of raced against wall-clock sleeps: the original
        // "wait for one poll, stop(), sleep 50ms, assert no growth" version
        // flaked under load, because stop() only sets a cancellation flag —
        // it doesn't wait for an already-in-flight linkStatus() call to
        // notice. Holding that call open makes the interleaving explicit:
        // stop() fires while the FIRST call is provably still suspended, so
        // releasing it and observing no SECOND call is a deterministic
        // check that the loop respects cancellation before it re-polls.
        let fake = FakeDeviceLinker()
        fake.holdStatus = true
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(fake.statusCount >= 1)
        vm.stop()
        let count = fake.statusCount
        fake.releaseStatus()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.statusCount, count)
    }

    func test_stop_duringApproveRegenerate_abandonsStaleSession() async {
        // Reproduces the orphan-poll-loop bug: approve() reacts to a
        // .notFound (code expired right as the tap landed) by calling
        // stop() then awaiting startSession() to mint a fresh code — all
        // inside the button tap's own unstructured Task, which the view's
        // onDisappear can't reach. If the user leaves the screen while that
        // regenerate's linkStart() is still in flight, onDisappear's stop()
        // has nothing to cancel (the old pollTask is already nil), and an
        // unguarded startSession() would resurrect phase + spawn a brand
        // new, uncancellable poll loop once linkStart() finally resolves.
        // Held+released (not raced against sleeps) so the interleaving is
        // deterministic: stop() is proven to land while linkStart() is
        // provably still suspended.
        let fake = FakeDeviceLinker()
        fake.statusScript = [.success(.claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1", expiresIn: 5))]
        fake.approveResult = .failure(JournalAPIError.notFound)
        fake.startResults = [.success(LinkStart(code: "KTNM-3VQ8", expiresIn: 120)),
                             .success(LinkStart(code: "WXYZ-2345", expiresIn: 120))]
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(vm.phase == .claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1"))

        fake.holdStart = true
        let approveTask = Task { await vm.approve() }
        await waitUntil(fake.startCount >= 2) // regenerate's linkStart() is in flight, held open

        vm.stop() // the onDisappear that should orphan this regenerate

        fake.releaseStart()
        await approveTask.value

        // The abandoned regenerate must not resurrect phase...
        XCTAssertEqual(vm.phase, .claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1"))
        // ...nor spawn a poll loop nothing can stop.
        let statusCountAfterAbandon = fake.statusCount
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.statusCount, statusCountAfterAbandon)
    }

    func test_approve_whileStatusInFlight_doesNotResurrectClaimed() async {
        // Finding 1: a linkStatus() call already in flight when approve()
        // runs its stop()+terminal-phase can resolve LATE and overwrite
        // .approved back to .claimed. Gated (held+released) so the
        // interleaving is exact: the second status call is provably parked
        // in flight when approve() lands, then released to prove the loop
        // abandons (generation bumped by stop()) before writing phase.
        let fake = FakeDeviceLinker()
        fake.statusScript = [.success(.claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1", expiresIn: 90))]
        fake.holdStatus = true
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(fake.statusCount >= 1)            // first linkStatus parked
        fake.releaseStatus()                              // -> returns .claimed
        await waitUntil(vm.phase == .claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1")
                        && fake.statusCount >= 2)         // second linkStatus now parked in flight
        await vm.approve()                                // terminal: stop() + .approved
        XCTAssertEqual(vm.phase, .approved)
        fake.releaseStatus()                              // the in-flight status resolves late
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.phase, .approved)               // must NOT be resurrected to .claimed
    }

    func test_transportErrorOnStatus_keepsShowingAndKeepsPolling() async {
        let fake = FakeDeviceLinker()
        fake.statusScript = [.failure(JournalAPIError.transport("offline")),
                             .success(.waiting(expiresIn: 90))]
        let vm = makeVM(fake)
        await vm.start()
        await waitUntil(fake.statusCount >= 2)
        XCTAssertEqual(vm.phase, .showing(code: "KTNM-3VQ8")) // never dropped to an error screen
        vm.stop()
    }

    private final class FakeRelay: RelayRendezvousing, @unchecked Sendable {
        var offerResult: Result<Void, Error> = .success(())
        private(set) var offers: [(rid: String, server: String, code: String)] = []
        /// Same gated pattern as `FakeDeviceLinker.holdStatus` — needed to
        /// deterministically land inside `offerRendezvous`'s await so a
        /// concurrent status poll can be interleaved at an exact point
        /// instead of raced against wall-clock sleeps.
        var holdOffer = false
        private(set) var offerGateReached = false
        private var offerContinuations: [CheckedContinuation<Void, Never>] = []
        private var bankedOfferReleases = 0
        /// Banked-release gate — same rationale as FakeDeviceLinker.gateLock:
        /// a release landing before the park must not be lost.
        private let gateLock = NSLock()

        func releaseOffer() {
            gateLock.lock()
            let toResume = offerContinuations
            offerContinuations.removeAll()
            if toResume.isEmpty { bankedOfferReleases += 1 }
            gateLock.unlock()
            toResume.forEach { $0.resume() }
        }

        func createRendezvous() async throws -> Rendezvous { fatalError("unused") }
        func pollRendezvous(rid: String, secret: String) async throws -> RendezvousPollResult { fatalError("unused") }
        func offerRendezvous(rid: String, server: String, code: String) async throws {
            if holdOffer {
                offerGateReached = true
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    gateLock.lock()
                    if bankedOfferReleases > 0 {
                        bankedOfferReleases -= 1
                        gateLock.unlock()
                        c.resume()
                    } else {
                        offerContinuations.append(c)
                        gateLock.unlock()
                    }
                }
            }
            offers.append((rid, server, code))
            try offerResult.get()
        }
    }

    private static let rid = "23456789BCDFGHJKMNPQRSTVWX"
    private static let rlinkPayload = "matron://rlink?v=1&rid=23456789BCDFGHJKMNPQRSTVWX"

    func test_offerScanned_sendsTheLiveSessionCodeAndServer() async {
        let fake = FakeDeviceLinker()
        fake.startResults = [.success(LinkStart(code: "2345-6789", expiresIn: 120))]
        let relay = FakeRelay()
        let vm = DeviceLinkViewModel(api: fake, serverURL: URL(string: "https://chat.example.com")!,
                                     relay: relay, pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        await vm.start()
        XCTAssertEqual(vm.phase, .showing(code: "2345-6789"))
        let startCountBeforeOffer = fake.startCount
        await vm.offerScanned(Self.rlinkPayload)
        XCTAssertEqual(relay.offers.count, 1)
        XCTAssertEqual(relay.offers[0].rid, Self.rid)
        XCTAssertEqual(relay.offers[0].server, "https://chat.example.com")
        XCTAssertEqual(relay.offers[0].code, "2345-6789")
        XCTAssertEqual(vm.noticeMessage, "Sent — approve the request when it appears.")
        // CRITICAL: offerScanned must never call linkStart() — a second
        // linkStart would replace the live session whose code the Show tab
        // displays, invalidating the code just handed to the relay.
        XCTAssertEqual(fake.startCount, startCountBeforeOffer, "offerScanned must not start a new link session")
    }

    func test_offerScanned_parseFailures_neverTouchTheRelay() async {
        let fake = FakeDeviceLinker()
        fake.startResults = [.success(LinkStart(code: "2345-6789", expiresIn: 120))]
        let relay = FakeRelay()
        let vm = DeviceLinkViewModel(api: fake, serverURL: URL(string: "https://chat.example.com")!,
                                     relay: relay, pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        await vm.start()
        await vm.offerScanned("matron://rlink?v=9&rid=\(Self.rid)")
        XCTAssertEqual(vm.noticeMessage, "This QR code needs a newer version of Matron.")
        await vm.offerScanned("https://not-matron.example.com")
        XCTAssertEqual(vm.noticeMessage, "Not a Matron link code.")
        XCTAssertTrue(relay.offers.isEmpty)
    }

    func test_offerScanned_relayOutcomes_mapToNotices() async {
        for (result, notice): (Result<Void, Error>, String) in [
            (.failure(RelayError.conflict), "That code was already used by another device."),
            (.failure(RelayError.notFound), "That code expired — ask the computer to show a fresh one."),
            (.failure(RelayError.transport("down")), "Couldn't reach the Matron relay — try again."),
        ] {
            let fake = FakeDeviceLinker()
            fake.startResults = [.success(LinkStart(code: "2345-6789", expiresIn: 120))]
            let relay = FakeRelay()
            relay.offerResult = result
            let vm = DeviceLinkViewModel(api: fake, serverURL: URL(string: "https://chat.example.com")!,
                                         relay: relay, pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
            await vm.start()
            let startCountBeforeOffer = fake.startCount
            await vm.offerScanned(Self.rlinkPayload)
            XCTAssertEqual(vm.noticeMessage, notice)
            XCTAssertEqual(fake.startCount, startCountBeforeOffer, "offerScanned must not start a new link session")
        }
    }

    func test_offerScanned_withoutALiveCode_asksToRetry() async {
        let fake = FakeDeviceLinker()
        fake.startResults = [.failure(JournalAPIError.transport("down"))] // start fails → no .showing code
        let relay = FakeRelay()
        let vm = DeviceLinkViewModel(api: fake, serverURL: URL(string: "https://chat.example.com")!,
                                     relay: relay, pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        await vm.start()
        await vm.offerScanned(Self.rlinkPayload)
        XCTAssertTrue(relay.offers.isEmpty)
        XCTAssertEqual(vm.noticeMessage, "Still fetching a link code — try scanning again in a moment.")
    }

    func test_offerScanned_reentrant_ignoresSecondScanWhileFirstOfferInFlight() async {
        // A double-fired scan (e.g. the scanner callback firing twice for
        // one frame) must not double-offer: a second offerRendezvous while
        // the first is still in flight would either race the relay or, if
        // it lands after the first succeeds, spuriously show "already used
        // by another device" over what was actually a clean single offer.
        let fake = FakeDeviceLinker()
        fake.startResults = [.success(LinkStart(code: "2345-6789", expiresIn: 120))]
        let relay = FakeRelay()
        relay.holdOffer = true
        let vm = DeviceLinkViewModel(api: fake, serverURL: URL(string: "https://chat.example.com")!,
                                     relay: relay, pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        await vm.start()
        XCTAssertEqual(vm.phase, .showing(code: "2345-6789"))

        let firstOffer = Task { await vm.offerScanned(Self.rlinkPayload) }
        await waitUntil(relay.offerGateReached)

        // Fires while the first offer is still held open — must be a no-op.
        await vm.offerScanned(Self.rlinkPayload)
        XCTAssertTrue(relay.offers.isEmpty, "the reentrant call must not have reached the relay yet")

        relay.releaseOffer()
        await firstOffer.value

        XCTAssertEqual(relay.offers.count, 1, "exactly one offer must have been recorded")
        XCTAssertEqual(vm.noticeMessage, "Sent — approve the request when it appears.")
        vm.stop()
    }

    // MARK: Finding 2 — offerScanned must inhibit poll-driven regeneration

    func test_offerScanned_inhibitsPollRegenerationWhileOfferInFlight() async {
        // Reproduces the race: a status 404 while offerRendezvous() is
        // awaiting must not regenerate the session (which would replace
        // the code the relay is in the middle of handing to the desktop).
        // Held+released (not raced against sleeps) so the interleaving is
        // deterministic: the offer is provably in flight when the poll
        // loop tries — and fails — to regenerate.
        let fake = FakeDeviceLinker()
        fake.startResults = [.success(LinkStart(code: "2345-6789", expiresIn: 120)),
                             .success(LinkStart(code: "WXYZ-2345", expiresIn: 120))]
        // First 404 lands *during* the offer (parked via holdStatus below),
        // second 404 arrives after the offer resolves and must regenerate,
        // then the regenerated session settles on .waiting.
        fake.statusScript = [.failure(JournalAPIError.notFound),
                             .failure(JournalAPIError.notFound),
                             .success(.waiting(expiresIn: 100))]
        fake.holdStatus = true
        let relay = FakeRelay()
        relay.holdOffer = true
        let vm = DeviceLinkViewModel(api: fake, serverURL: URL(string: "https://chat.example.com")!,
                                     relay: relay, pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        await vm.start()
        XCTAssertEqual(vm.phase, .showing(code: "2345-6789"))

        await waitUntil(fake.statusCount >= 1)           // a linkStatus is parked in flight
        let offerTask = Task { await vm.offerScanned(Self.rlinkPayload) }
        await waitUntil(relay.offerGateReached)          // offer provably open, isSubmitting == true
        fake.holdStatus = false
        fake.releaseStatus()                             // parked call resolves to 404 while the offer is open

        // Give the poll loop several intervals' worth of time to try (and,
        // pre-fix, succeed at) regenerating while the offer sits open.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.startCount, 1, "poll must not regenerate the session while an offer is in flight")
        XCTAssertEqual(vm.phase, .showing(code: "2345-6789"))

        relay.releaseOffer()
        await offerTask.value

        XCTAssertEqual(relay.offers.count, 1)
        XCTAssertEqual(relay.offers[0].code, "2345-6789", "must offer the code that was live when the scan happened")

        // The offer has resolved and isSubmitting has cleared — the poll
        // loop must still be alive to notice the (still-404ing) session
        // and regenerate. Pre-fix, the `!isSubmitting` disjunct in the
        // notFound handler RETURNS instead of skipping, permanently killing
        // the loop when the parked 404 above resolved — so the phone is
        // stuck on the dead/expired QR forever and this never happens.
        await waitUntil(vm.phase == .showing(code: "WXYZ-2345"))
        XCTAssertEqual(vm.phase, .showing(code: "WXYZ-2345"),
                       "poll loop must survive the in-flight offer and regenerate the expired session")
        XCTAssertEqual(fake.startCount, 2, "startSession must run again once the offer clears isSubmitting")
        vm.stop()
    }

    // MARK: Finding 3 — non-.showing notice must match loading vs. terminal

    func test_offerScanned_whileLoading_asksToRetry() async {
        let fake = FakeDeviceLinker()
        fake.holdStart = true
        let relay = FakeRelay()
        let vm = DeviceLinkViewModel(api: fake, serverURL: URL(string: "https://chat.example.com")!,
                                     relay: relay, pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        let startTask = Task { await vm.start() }
        await waitUntil(fake.startCount >= 1)
        XCTAssertEqual(vm.phase, .loading)

        await vm.offerScanned(Self.rlinkPayload)
        XCTAssertEqual(vm.noticeMessage, "Still fetching a link code — try scanning again in a moment.")
        XCTAssertTrue(relay.offers.isEmpty)

        fake.releaseStart()
        await startTask.value
        vm.stop()
    }

    func test_offerScanned_terminalPhases_sayLinkSessionInProgress() async {
        let relay = FakeRelay()

        let fakeClaimed = FakeDeviceLinker()
        fakeClaimed.statusScript = [.success(.claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1", expiresIn: 90))]
        let vmClaimed = DeviceLinkViewModel(api: fakeClaimed, serverURL: URL(string: "https://chat.example.com")!,
                                            relay: relay, pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        await vmClaimed.start()
        await waitUntil(vmClaimed.phase == .claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1"))
        await vmClaimed.offerScanned(Self.rlinkPayload)
        XCTAssertEqual(vmClaimed.noticeMessage,
                       "A link session is already in progress — finish it before linking another device.")
        vmClaimed.stop()

        let fakeApproved = FakeDeviceLinker()
        fakeApproved.statusScript = [.success(.claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1", expiresIn: 90))]
        let vmApproved = DeviceLinkViewModel(api: fakeApproved, serverURL: URL(string: "https://chat.example.com")!,
                                             relay: relay, pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        await vmApproved.start()
        await waitUntil(vmApproved.phase == .claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1"))
        await vmApproved.approve()
        XCTAssertEqual(vmApproved.phase, .approved)
        await vmApproved.offerScanned(Self.rlinkPayload)
        XCTAssertEqual(vmApproved.noticeMessage,
                       "A link session is already in progress — finish it before linking another device.")

        let fakeDenied = FakeDeviceLinker()
        fakeDenied.statusScript = [.success(.claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1", expiresIn: 90))]
        let vmDenied = DeviceLinkViewModel(api: fakeDenied, serverURL: URL(string: "https://chat.example.com")!,
                                           relay: relay, pollInterval: .milliseconds(1), errorPollInterval: .milliseconds(1))
        await vmDenied.start()
        await waitUntil(vmDenied.phase == .claimed(deviceName: "Pixel 9", requesterIP: "1.1.1.1"))
        await vmDenied.deny()
        XCTAssertEqual(vmDenied.phase, .denied)
        await vmDenied.offerScanned(Self.rlinkPayload)
        XCTAssertEqual(vmDenied.noticeMessage,
                       "A link session is already in progress — finish it before linking another device.")

        XCTAssertTrue(relay.offers.isEmpty, "none of the terminal phases should have reached the relay")
    }
}
