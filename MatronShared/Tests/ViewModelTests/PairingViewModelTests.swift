import XCTest
@testable import MatronViewModels
@testable import MatronJournal

/// PairingViewModel drives the Add-agent modal: code entry → mandatory
/// requester-IP preview → name + approve → wait-for-claim polling. Tests
/// inject near-zero debounce/poll intervals and a controllable `now`.
@MainActor
final class PairingViewModelTests: XCTestCase {
    private func makeVM(_ fake: FakeDevicesProvider,
                        existingNames: [String] = [],
                        now: @escaping () -> Date = Date.init) -> PairingViewModel {
        PairingViewModel(api: fake, existingNames: existingNames, now: now,
                         pollInterval: .milliseconds(1), previewDebounce: .milliseconds(1))
    }

    /// Polls the main actor until `condition` or the deadline — the VM's
    /// internal tasks hop actors, so state lands a few hops later.
    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func test_codeInput_autoFormatsForDisplay() {
        let vm = makeVM(FakeDevicesProvider())
        vm.codeInput = "ktnm3vq8"
        XCTAssertEqual(vm.codeInput, "KTNM-3VQ8")
        vm.codeInput = "ktn"
        XCTAssertEqual(vm.codeInput, "KTN")
    }

    func test_plausibleCode_triggersPreview_andPhaseCarriesIP() async {
        let fake = FakeDevicesProvider()
        fake.previewResult = .success(PairPreview(requesterIP: "65.108.10.252", expiresIn: 412))
        let vm = makeVM(fake)
        vm.codeInput = "ktnm-3vq8"
        await waitUntil(vm.phase == .preview(requesterIP: "65.108.10.252"))
        XCTAssertEqual(vm.phase, .preview(requesterIP: "65.108.10.252"))
        XCTAssertEqual(fake.previewedCodes.last, "KTNM3VQ8", "preview must send the normalized code")
        XCTAssertNotNil(vm.expiresAt)
    }

    func test_implausibleCode_neverPreviews() async {
        let fake = FakeDevicesProvider()
        let vm = makeVM(fake)
        vm.codeInput = "ktn"
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fake.previewedCodes.isEmpty)
        XCTAssertEqual(vm.phase, .enterCode)
    }

    func test_preview404_showsSpecCopy() async {
        let fake = FakeDevicesProvider()
        fake.previewResult = .failure(.notFound)
        let vm = makeVM(fake)
        vm.codeInput = "ktnm-3vq8"
        await waitUntil(vm.errorMessage != nil)
        XCTAssertEqual(vm.errorMessage, "Code not recognized or expired. Get a fresh code from the box and try again.")
        XCTAssertEqual(vm.phase, .enterCode)
    }

    func test_duplicateName_warnsButDoesNotBlock() {
        let vm = makeVM(FakeDevicesProvider(), existingNames: ["dev-7", "dan-mac"])
        vm.agentName = "dev-7"
        XCTAssertEqual(vm.duplicateNameWarning, "You already have an agent called dev-7")
        vm.agentName = "dev-8"
        XCTAssertNil(vm.duplicateNameWarning)
    }

    func test_approve_conflict_showsSpecCopy() async {
        let fake = FakeDevicesProvider()
        fake.previewResult = .success(PairPreview(requesterIP: "1.2.3.4", expiresIn: 600))
        fake.approveError = .conflict
        let vm = makeVM(fake)
        vm.codeInput = "ktnm-3vq8"
        await waitUntil(vm.phase != .enterCode)
        vm.agentName = "dev-7"
        await vm.approve()
        XCTAssertEqual(vm.errorMessage, "This code was already approved.")
    }

    func test_approve_thenClaimDetectedByIDSnapshot_notName() async {
        let fake = FakeDevicesProvider()
        fake.previewResult = .success(PairPreview(requesterIP: "1.2.3.4", expiresIn: 600))
        // Pre-approve roster already contains an agent with the SAME name the
        // user picks — matching by name would "succeed" instantly and wrongly.
        let preexisting = device(3, kind: "agent", name: "dev-7", createdAt: 10)
        fake.rosters = [
            [preexisting],                                      // snapshot call
            [preexisting],                                      // first poll: not claimed yet
            [preexisting, device(9, kind: "agent", name: "dev-7", createdAt: 99)], // claimed
        ]
        let vm = makeVM(fake)
        vm.codeInput = "ktnm-3vq8"
        await waitUntil(vm.phase != .enterCode)
        vm.agentName = "dev-7"
        await vm.approve()
        await waitUntil(vm.phase == .success(agentName: "dev-7"))
        XCTAssertEqual(vm.phase, .success(agentName: "dev-7"))
        XCTAssertEqual(fake.approvals.count, 1)
        XCTAssertEqual(fake.approvals[0].code, "KTNM3VQ8")
        XCTAssertGreaterThanOrEqual(fake.devicesCalls, 3, "snapshot + at least two polls")
    }

    func test_waitForClaim_ttlExpiry_showsSpecCopy() async {
        let fake = FakeDevicesProvider()
        fake.previewResult = .success(PairPreview(requesterIP: "1.2.3.4", expiresIn: 600))
        fake.rosters = [[]]
        // Controllable clock: jump past the TTL right after approve.
        nonisolated(unsafe) var currentDate = Date(timeIntervalSince1970: 1_000)
        let vm = makeVM(fake, now: { currentDate })
        vm.codeInput = "ktnm-3vq8"
        await waitUntil(vm.phase != .enterCode)
        vm.agentName = "dev-7"
        currentDate = Date(timeIntervalSince1970: 1_000 + 601)
        await vm.approve()
        await waitUntil(vm.errorMessage != nil)
        XCTAssertEqual(vm.errorMessage, "The box never collected its token. Start again with a fresh code.")
        XCTAssertEqual(vm.phase, .enterCode, "expired pair returns to code entry")
    }

    func test_staleEditDuringApprove_cannotStompWaitState() async {
        let fake = FakeDevicesProvider()
        fake.previewResult = .success(PairPreview(requesterIP: "1.2.3.4", expiresIn: 600))
        fake.rosters = [[]]
        let vm = makeVM(fake)
        vm.codeInput = "ktnm-3vq8"
        await waitUntil(vm.phase == .preview(requesterIP: "1.2.3.4"))
        vm.agentName = "dev-7"
        // Approve suspends mid-flight; the user keeps typing in the still-
        // visible code field, queueing a fresh (slow) preview.
        fake.approveDelay = .milliseconds(100)
        fake.previewDelay = .milliseconds(300)
        let approving = Task { await vm.approve() }
        try? await Task.sleep(for: .milliseconds(20))
        vm.codeInput = "BCDF-GHJK"
        await approving.value
        XCTAssertEqual(vm.phase, .waitingForClaim)
        // Let the stale preview response land — it must not pull the flow
        // back to .preview or surface an error.
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(vm.phase, .waitingForClaim, "a late preview response must not leave the wait state")
        XCTAssertNil(vm.errorMessage)
    }

    func test_approve_secondTapWhileInFlight_isIgnored() async {
        let fake = FakeDevicesProvider()
        fake.previewResult = .success(PairPreview(requesterIP: "1.2.3.4", expiresIn: 600))
        fake.rosters = [[]]
        fake.approveDelay = .milliseconds(100)
        let vm = makeVM(fake)
        vm.codeInput = "ktnm-3vq8"
        await waitUntil(vm.phase == .preview(requesterIP: "1.2.3.4"))
        vm.agentName = "dev-7"
        let first = Task { await vm.approve() }
        try? await Task.sleep(for: .milliseconds(20))
        await vm.approve() // impatient second tap while the first is in flight
        await first.value
        XCTAssertEqual(fake.approvals.count, 1, "reentrant approve must not fire a second server call")
        XCTAssertEqual(vm.phase, .waitingForClaim)
        XCTAssertNil(vm.errorMessage, "the duplicate tap must not surface a conflict error")
    }

    func test_cancelWaiting_stopsPolling() async {
        let fake = FakeDevicesProvider()
        fake.previewResult = .success(PairPreview(requesterIP: "1.2.3.4", expiresIn: 600))
        fake.rosters = [[]]
        let vm = makeVM(fake)
        vm.codeInput = "ktnm-3vq8"
        await waitUntil(vm.phase != .enterCode)
        vm.agentName = "dev-7"
        await vm.approve()
        XCTAssertEqual(vm.phase, .waitingForClaim)
        vm.cancelWaiting()
        try? await Task.sleep(for: .milliseconds(30))
        let callsAfterCancel = fake.devicesCalls
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.devicesCalls, callsAfterCancel, "polling must stop after cancel")
    }
}
