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

    func releaseStatus() {
        statusContinuations.forEach { $0.resume() }
        statusContinuations.removeAll()
    }

    /// Same gated pattern as `holdStatus`, for `linkStart()` — needed to
    /// deterministically land inside a regenerate's `linkStart` await so a
    /// concurrent `stop()` can be interleaved at an exact point instead of
    /// raced against wall-clock sleeps.
    var holdStart = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func releaseStart() {
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()
    }

    private(set) var startCount = 0
    private(set) var statusCount = 0
    private(set) var approvedCodes: [String] = []
    private(set) var deniedCodes: [String] = []

    func linkStart() async throws -> LinkStart {
        startCount += 1
        if holdStart {
            await withCheckedContinuation { startContinuations.append($0) }
        }
        let result = startResults.count > 1 ? startResults.removeFirst() : startResults[0]
        return try result.get()
    }
    func linkStatus() async throws -> LinkStatus {
        statusCount += 1
        if holdStatus {
            await withCheckedContinuation { statusContinuations.append($0) }
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
}
