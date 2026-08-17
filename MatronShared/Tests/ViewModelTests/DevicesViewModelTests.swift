import XCTest
@testable import MatronViewModels
@testable import MatronJournal

/// Recording fake for the devices/pairing API surface. Rosters are served
/// FIFO from `rosters` (last one repeats); errors are thrown per-call via
/// the closures.
final class FakeDevicesProvider: DevicesProviding, @unchecked Sendable {
    var rosters: [[DeviceDTO]] = [[]]
    var devicesError: JournalAPIError?
    var revokeError: JournalAPIError?
    var renameError: JournalAPIError?
    var previewResult: Result<PairPreview, JournalAPIError> = .failure(.notFound)
    var approveError: JournalAPIError?
    /// Per-call latency, for tests that need a request suspended while the
    /// view model does something else (races between preview and approve).
    var previewDelay: Duration = .zero
    var approveDelay: Duration = .zero
    /// Deterministic alternative to the delays for interleaving tests: when
    /// set, the call suspends after recording its arguments until the test
    /// calls the matching `release*()`. Real-time delays make interleavings
    /// a coin flip on loaded CI runners; a gate guarantees them.
    var holdPreview = false
    var holdApprove = false
    private var previewContinuations: [CheckedContinuation<Void, Never>] = []
    private var approveContinuations: [CheckedContinuation<Void, Never>] = []

    func releasePreview() {
        previewContinuations.forEach { $0.resume() }
        previewContinuations.removeAll()
    }

    func releaseApprove() {
        approveContinuations.forEach { $0.resume() }
        approveContinuations.removeAll()
    }

    private(set) var devicesCalls = 0
    private(set) var revokedIDs: [Int64] = []
    private(set) var renamed: [(id: Int64, name: String)] = []
    private(set) var tagged: [(id: Int64, tagChar: String?)] = []
    private(set) var previewedCodes: [String] = []
    private(set) var approvals: [(code: String, name: String, tagChar: String?)] = []

    func renameDevice(id: Int64, name: String) async throws -> DeviceDTO {
        renamed.append((id, name))
        if let renameError { throw renameError }
        // Echo the roster forward with the new name, so the view model's
        // post-rename refresh sees what a real server would return.
        rosters = rosters.map { roster in
            roster.map { d in
                d.id == id
                    ? DeviceDTO(id: d.id, kind: d.kind, name: name, createdAt: d.createdAt,
                                cursor: d.cursor, lag: d.lag, lastSeenAt: d.lastSeenAt,
                                isSelf: d.isSelf, connected: d.connected)
                    : d
            }
        }
        return rosters[0].first { $0.id == id }
            ?? DeviceDTO(id: id, kind: "", name: name, createdAt: 0, cursor: 0, lag: 0,
                         lastSeenAt: nil, isSelf: false)
    }

    func devices() async throws -> [DeviceDTO] {
        devicesCalls += 1
        if let devicesError { throw devicesError }
        return rosters.count > 1 ? rosters.removeFirst() : rosters[0]
    }

    func revokeDevice(id: Int64) async throws {
        revokedIDs.append(id)
        if let revokeError { throw revokeError }
    }

    func pairPreview(code: String) async throws -> PairPreview {
        previewedCodes.append(code)
        if holdPreview {
            await withCheckedContinuation { previewContinuations.append($0) }
        }
        if previewDelay > .zero { try? await Task.sleep(for: previewDelay) }
        return try previewResult.get()
    }

    func pairApprove(code: String, agentName: String, tagChar: String?) async throws {
        approvals.append((code, agentName, tagChar))
        if holdApprove {
            await withCheckedContinuation { approveContinuations.append($0) }
        }
        if approveDelay > .zero { try? await Task.sleep(for: approveDelay) }
        if let approveError { throw approveError }
    }

    var tagError: JournalAPIError?

    func setDeviceTag(id: Int64, tagChar: String?) async throws {
        tagged.append((id, tagChar))
        if let tagError { throw tagError }
        // Echo the roster forward with the new tag, like renameDevice does.
        rosters = rosters.map { roster in
            roster.map { d in
                d.id == id
                    ? DeviceDTO(id: d.id, kind: d.kind, name: d.name, createdAt: d.createdAt,
                                cursor: d.cursor, lag: d.lag, lastSeenAt: d.lastSeenAt,
                                isSelf: d.isSelf, connected: d.connected, tagChar: tagChar)
                    : d
            }
        }
    }
}

func device(_ id: Int64, kind: String = "client", name: String = "d\(Int.random(in: 0...9))",
            createdAt: Int64 = 0, lag: Int64 = 0, lastSeenAt: Int64? = nil,
            isSelf: Bool = false) -> DeviceDTO {
    DeviceDTO(id: id, kind: kind, name: name, createdAt: createdAt, cursor: 0,
              lag: lag, lastSeenAt: lastSeenAt, isSelf: isSelf)
}

@MainActor
final class DevicesViewModelTests: XCTestCase {
    func test_refresh_sortsClientsFirstThenAgents_eachNewestFirst() async {
        let fake = FakeDevicesProvider()
        fake.rosters = [[
            device(1, kind: "agent", createdAt: 100),
            device(2, kind: "client", createdAt: 50),
            device(3, kind: "agent", createdAt: 300),
            device(4, kind: "client", createdAt: 200),
        ]]
        let vm = DevicesViewModel(api: fake, onSelfRevoked: {})
        await vm.refresh()
        XCTAssertEqual(vm.devices.map(\.id), [4, 2, 3, 1])
        XCTAssertNil(vm.errorMessage)
    }

    func test_revoke_otherDevice_hitsAPIAndRefetches() async {
        let fake = FakeDevicesProvider()
        let other = device(9, kind: "agent")
        fake.rosters = [[other], []]
        let vm = DevicesViewModel(api: fake, onSelfRevoked: {})
        await vm.refresh()
        await vm.revoke(other)
        XCTAssertEqual(fake.revokedIDs, [9])
        XCTAssertEqual(fake.devicesCalls, 2, "revoke must re-fetch the roster")
        XCTAssertTrue(vm.devices.isEmpty)
    }

    func test_revoke_notFound_isTreatedAsAlreadyGone() async {
        let fake = FakeDevicesProvider()
        let other = device(9)
        fake.rosters = [[other], []]
        fake.revokeError = .notFound
        let vm = DevicesViewModel(api: fake, onSelfRevoked: {})
        await vm.refresh()
        await vm.revoke(other)
        XCTAssertNil(vm.errorMessage, "404 = already revoked elsewhere = success")
        XCTAssertEqual(fake.devicesCalls, 2)
    }

    func test_revoke_self_firesCallbackInsteadOfRefetch() async {
        let fake = FakeDevicesProvider()
        let me = device(1, isSelf: true)
        fake.rosters = [[me]]
        var selfRevoked = false
        let vm = DevicesViewModel(api: fake, onSelfRevoked: { selfRevoked = true })
        await vm.refresh()
        await vm.revoke(me)
        XCTAssertTrue(selfRevoked)
        XCTAssertEqual(fake.devicesCalls, 1, "no refetch on a token we just revoked")
    }

    func test_revoke_success_refetchFails_rowStillDisappears() async {
        let fake = FakeDevicesProvider()
        let other = device(9, kind: "agent")
        fake.rosters = [[other]]
        let vm = DevicesViewModel(api: fake, onSelfRevoked: {})
        await vm.refresh()
        // Revoke succeeds server-side; the confirming refetch then fails.
        // The device is gone on the server, so the row must not linger.
        fake.devicesError = .transport("offline")
        await vm.revoke(other)
        XCTAssertEqual(fake.revokedIDs, [9])
        XCTAssertTrue(vm.devices.isEmpty, "server already dropped the device — the row must not survive a failed refetch")
        XCTAssertNotNil(vm.errorMessage, "the refetch failure is still surfaced")
    }

    func test_revoke_serverError_surfacesMessageAndKeepsRow() async {
        let fake = FakeDevicesProvider()
        let other = device(9)
        fake.rosters = [[other]]
        fake.revokeError = .http(status: 500, message: "boom")
        var selfRevoked = false
        let vm = DevicesViewModel(api: fake, onSelfRevoked: { selfRevoked = true })
        await vm.refresh()
        await vm.revoke(other)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(selfRevoked)
        XCTAssertEqual(vm.devices.map(\.id), [9])
    }

    func test_displayHelpers_lastSeenNeverAndLag() {
        let never = device(1, kind: "agent", lastSeenAt: nil)
        XCTAssertEqual(never.lastSeenText(), "Never")
        XCTAssertEqual(never.symbolName, "terminal")
        XCTAssertEqual(never.lagText, "Up to date")
        let behind = device(2, kind: "client", lag: 123, lastSeenAt: 1_784_500_000_000)
        XCTAssertEqual(behind.lagText, "123 events behind")
        XCTAssertEqual(behind.symbolName, "laptopcomputer")
        XCTAssertNotEqual(behind.lastSeenText(), "Never")
        XCTAssertEqual(device(3, lag: 1).lagText, "1 event behind")
    }

    func test_refresh_errorSurfacesMessage() async {
        struct Failing: DevicesProviding {
            func devices() async throws -> [DeviceDTO] { throw JournalAPIError.transport("offline") }
            func revokeDevice(id: Int64) async throws {}
            func renameDevice(id: Int64, name: String) async throws -> DeviceDTO {
                throw JournalAPIError.transport("offline")
            }
            func pairPreview(code: String) async throws -> PairPreview { throw JournalAPIError.notFound }
            func pairApprove(code: String, agentName: String, tagChar: String?) async throws {}
            func setDeviceTag(id: Int64, tagChar: String?) async throws {
                throw JournalAPIError.transport("offline")
            }
        }
        let vm = DevicesViewModel(api: Failing(), onSelfRevoked: {})
        await vm.refresh()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    func test_rename_updatesTheRosterAndSurfacesFailures() async {
        let fake = FakeDevicesProvider()
        fake.rosters = [[DeviceDTO(id: 7, kind: "agent", name: "dev-9", createdAt: 1,
                                   cursor: 0, lag: 0, lastSeenAt: nil, isSelf: false)]]
        let vm = DevicesViewModel(api: fake, onSelfRevoked: {})
        await vm.refresh()

        await vm.rename(vm.devices[0], to: "dev-y")
        XCTAssertEqual(fake.renamed.map(\.id), [7])
        XCTAssertEqual(fake.renamed.map(\.name), ["dev-y"])
        XCTAssertEqual(vm.devices.first?.name, "dev-y")
        XCTAssertNil(vm.errorMessage)

        // A server refusal leaves the roster alone and explains itself.
        fake.renameError = .forbidden
        await vm.rename(vm.devices[0], to: "dev-z")
        XCTAssertEqual(vm.devices.first?.name, "dev-y")
        XCTAssertEqual(vm.errorMessage?.contains("dev-y"), true)
    }

    func test_validateName_matchesTheServerRules() {
        // Mirrors the journal's own check so the user gets told before a 400.
        XCTAssertNil(DevicesViewModel.validate(name: "dev-y"))
        XCTAssertNil(DevicesViewModel.validate(name: String(repeating: "y", count: 40)))
        XCTAssertNotNil(DevicesViewModel.validate(name: ""))
        XCTAssertNotNil(DevicesViewModel.validate(name: "   "))
        XCTAssertNotNil(DevicesViewModel.validate(name: String(repeating: "y", count: 41)))
    }

    func test_setTag_sendsFirstGraphemeNilForBlank_andSurfacesFailures() async {
        let fake = FakeDevicesProvider()
        fake.rosters = [[DeviceDTO(id: 7, kind: "agent", name: "dev-9", createdAt: 1,
                                   cursor: 0, lag: 0, lastSeenAt: nil, isSelf: false)]]
        let vm = DevicesViewModel(api: fake, onSelfRevoked: {})
        await vm.refresh()

        // Only the first grapheme of the draft travels; the roster refresh
        // shows the stored value.
        await vm.setTag(vm.devices[0], toDraft: " 🦊x ")
        XCTAssertEqual(fake.tagged.map(\.id), [7])
        XCTAssertEqual(fake.tagged.map(\.tagChar), ["🦊"])
        XCTAssertEqual(vm.devices.first?.tagChar, "🦊")
        XCTAssertNil(vm.errorMessage)

        // A blank draft clears: nil on the wire = back to automatic.
        await vm.setTag(vm.devices[0], toDraft: "   ")
        XCTAssertEqual(fake.tagged.last?.tagChar, nil as String?)
        XCTAssertNil(vm.devices.first?.tagChar)

        // A server refusal leaves the roster alone and explains itself.
        fake.tagError = .forbidden
        await vm.setTag(vm.devices[0], toDraft: "z")
        XCTAssertNil(vm.devices.first?.tagChar)
        XCTAssertEqual(vm.errorMessage?.contains("dev-9"), true)
    }

    func test_tagCharFromDraft_keepsOneGraphemeMapsBlankToNil() {
        XCTAssertEqual(DevicesViewModel.tagChar(fromDraft: " mz "), "m")
        XCTAssertEqual(DevicesViewModel.tagChar(fromDraft: "👩‍💻x"), "👩‍💻")
        XCTAssertNil(DevicesViewModel.tagChar(fromDraft: ""))
        XCTAssertNil(DevicesViewModel.tagChar(fromDraft: "   "))
    }

    func test_tagCharFromDraft_sievesOverlongAndInvisibleClustersToNil() {
        // A Character is a grapheme cluster, not one code point: a Zalgo
        // combining stack or a long ZWJ chain is "one character" that
        // renders many glyphs wide — over 16 scalars sieves to nil (clear).
        XCTAssertNil(DevicesViewModel.tagChar(fromDraft: "a" + String(repeating: "\u{0301}", count: 60)))
        // 9 women + 8 ZWJs = 17 scalars, one over the bound.
        XCTAssertNil(DevicesViewModel.tagChar(
            fromDraft: Array(repeating: "👩", count: 9).joined(separator: "\u{200D}")))
        // A real compound emoji stays under the bound and survives whole.
        XCTAssertEqual(DevicesViewModel.tagChar(fromDraft: "👨‍👩‍👧‍👦"), "👨‍👩‍👧‍👦")
        // Invisible lead clusters (soft hyphen, RLO, LRI) would be a
        // non-nil tag rendering as nothing — suppressing the derived
        // letter with no visible explanation. They sieve to nil too.
        XCTAssertNil(DevicesViewModel.tagChar(fromDraft: "\u{00AD}q"))
        XCTAssertNil(DevicesViewModel.tagChar(fromDraft: "\u{202E}abc"))
        XCTAssertNil(DevicesViewModel.tagChar(fromDraft: "\u{2066}abc"))
    }
}
