import Foundation
import MatronAuth
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronStorage
import MatronViewModels

/// Made-up approval keys, requests and locked boxes for the render
/// harnesses of both apps. The device key is the shared test vectors'
/// throwaway key, so its fingerprint is always `7734 f909`.
enum ApprovalFixtures {
    static let vectorKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgqaOEaPyrULWgGII2
    I8K1o9uZmk/sYey5bvnLPX8BUNihRANCAARLRtjq1gcBhgKMY/2z6EE5XD7ftO77
    Pi5kz942lKetwVmch4YvlsC07mFCJUg9nHI75jpYAL4T960EWcUTBXxq
    -----END PRIVATE KEY-----
    """
    static let deviceKeyID = "7734f909e9f544078132cf4d9007db7ffc0b4a36a266f3e0488477995ee3552f"
    static let macKeyID = "3fa1c88e0b7d4c2e9a6f51d0e4b8c7a2915d6e3f0a4b7c8d9e1f2a3b4c5d6e7f"
    static let oldKeyID = "b02e41d7aa9c4f1e8d3b6a5c7e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f"
    static let requestKeyID = "c9d4e2f17a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5"
    static let thisDeviceID: Int64 = 3
    static let day = Date(timeIntervalSince1970: 1_794_500_000)

    enum Scene {
        /// No key on the account yet.
        case notSetUp
        /// This device and a Mac hold keys, one old key is removed, and a
        /// new laptop waits to be approved.
        case ready
        /// This device asked to be added and waits for the Mac.
        case waiting
        /// This device signed in again: its key is attached to no sign-in.
        case needsAttach
    }

    final class MemoryStore: SessionStore, @unchecked Sendable {
        private var values: [String: String] = [:]
        private let lock = NSLock()
        func set(_ value: String, forKey key: String) throws { lock.withLock { values[key] = value } }
        func get(key: String) throws -> String? { lock.withLock { values[key] } }
        func delete(key: String) throws { lock.withLock { values[key] = nil } }
    }

    struct API: ApprovalKeysProviding {
        let state: ApprovalKeysState
        func approvalKeys() async throws -> ApprovalKeysState { state }
        func approvalNonce() async throws -> ApprovalNonce { ApprovalNonce(nonce: "n", expiresAt: Date()) }
        func enrolApprovalKey(publicKey: String, name: String, password: String, code: String) async throws -> ApprovalKeyDTO {
            throw ApprovalKeyError.badCode
        }
        func requestApprovalKey(publicKey: String, name: String) async throws -> String { "kr_1" }
        func approveApprovalKeyRequest(id: String, approval: SignedApproval) async throws -> ApprovalKeyDTO { state.keys[0] }
        func revokeApprovalKey(keyID: String, approval: SignedApproval) async throws {}
        func revokeApprovalKey(keyID: String, password: String, code: String) async throws {}
        func attachApprovalKey(approval: SignedApproval) async throws -> ApprovalKeyDTO { state.keys[0] }
    }

    private static func key(_ id: String, _ name: String, device: Int64?, via: ApprovalKeyDTO.EnrolledVia,
                            daysAgo: Double, revokedDaysAgo: Double? = nil) -> ApprovalKeyDTO {
        ApprovalKeyDTO(keyID: id, name: name, deviceID: device, enrolledVia: via,
                       createdAt: day.addingTimeInterval(-daysAgo * 86_400),
                       revokedAt: revokedDaysAgo.map { day.addingTimeInterval(-$0 * 86_400) })
    }

    static func state(_ scene: Scene, thisDevice: String) -> ApprovalKeysState {
        let mac = key(macKeyID, "alice's MacBook Pro", device: 8, via: .device, daysAgo: 2)
        let old = key(oldKeyID, "alice's old iPad", device: nil, via: .password, daysAgo: 40, revokedDaysAgo: 3)
        switch scene {
        case .notSetUp:
            return ApprovalKeysState(enabled: true, journal: "journal.example", keys: [])
        case .ready:
            return ApprovalKeysState(
                enabled: true, journal: "journal.example",
                keys: [old, key(deviceKeyID, thisDevice, device: thisDeviceID, via: .password, daysAgo: 5), mac],
                requests: [ApprovalKeyRequestDTO(id: "kr_1", keyID: requestKeyID, name: "alice's Mac mini", createdAt: day)])
        case .waiting:
            return ApprovalKeysState(
                enabled: true, journal: "journal.example", keys: [mac],
                requests: [ApprovalKeyRequestDTO(id: "kr_2", keyID: deviceKeyID, name: thisDevice, createdAt: day)])
        case .needsAttach:
            return ApprovalKeysState(
                enabled: true, journal: "journal.example",
                keys: [key(deviceKeyID, thisDevice, device: nil, via: .password, daysAgo: 5), mac])
        }
    }

    /// The keys screen's model for a scene, with the keys already read.
    @MainActor
    static func screenModel(_ scene: Scene, thisDevice: String, method: String) async -> ApprovalKeysScreenModel {
        let store = ApprovalKeyStore(store: MemoryStore(), host: "journal.example", user: "alice")
        if scene != .notSetUp, let key = try? SoftwareApprovalKey(pem: vectorKeyPEM) {
            try? store.save(StoredApprovalKey(kind: .software, blob: key.rawRepresentation, publicKey: key.publicKey,
                                              biometryState: nil, createdAt: day))
        }
        let center = ApprovalCenter(api: API(state: state(scene, thisDevice: thisDevice)),
                                    keys: SoftwareKeyProvider(method: method), store: store, user: "alice",
                                    deviceID: thisDeviceID, deviceName: thisDevice)
        await center.refresh()
        return ApprovalKeysScreenModel(center: center, locale: Locale(identifier: "en_GB"),
                                       timeZone: TimeZone(identifier: "UTC")!)
    }

    // MARK: Confirm sheet

    private static func lines(_ subject: ApprovalSubject) -> [ApprovalConfirmView.Model.Line] {
        ApprovalSubjects.lines(subject).map { ApprovalConfirmView.Model.Line(key: $0.key, value: $0.value) }
    }

    /// A tap on a step-up item's button.
    static func tapModel(method: String) -> ApprovalConfirmView.Model {
        ApprovalConfirmView.Model(
            reference: "#7", headline: "Deploy the new build to production", button: "Approve",
            detail: "Build 4.2.0 passed its checks. Roll it out to production now?",
            subject: lines(["op": "deploy", "repo": "example/app", "commit": "9f2c1e7", "target": "production"]),
            method: method, fingerprint: "7734f909")
    }

    /// Approve on a spawn aimed at a protected box, with the task in full.
    static func consentModel(method: String) -> ApprovalConfirmView.Model {
        let task = "Run the test suite on the release branch and report which tests fail. Do not push anything."
        return ApprovalConfirmView.Model(
            reference: "#12", headline: "Start a session on box-a", button: "Approve", detail: task,
            subject: lines(ApprovalSubjects.spawn(ask: "0d6f2c1e-8a3b-4c5d-9e7f-1a2b3c4d5e6f", box: "box-a",
                                                  workdir: "~/app", task: task)),
            method: method, fingerprint: "7734f909")
    }

    /// An account action.
    static func accountModel(method: String) -> ApprovalConfirmView.Model {
        ApprovalConfirmView.Model(headline: "Change password", subject: lines(ApprovalSubjects.changePassword()),
                                  method: method, fingerprint: "7734f909")
    }

    /// Unlocking a locked box, sent to the box itself.
    static func unlockModel(method: String) -> ApprovalConfirmView.Model {
        ApprovalConfirmView.Model(
            headline: "Unlock box-a for 30 minutes",
            detail: "While it is unlocked, box-a takes instructions from this device only.",
            box: "box-a", subject: lines(ApprovalSubjects.unlockBox(box: "box-a", minutes: 30)),
            method: method, fingerprint: "7734f909")
    }

    /// A refused approval, with the key re-attached first.
    static func errorModel(method: String) -> ApprovalConfirmView.Model {
        var model = tapModel(method: method)
        model.attachesFirst = true
        model.error = JournalAPIError.approvalInvalidText("mismatch")
        return model
    }

    // MARK: Locked boxes

    /// Three boxes: one locked and protected, one unlocked for a while,
    /// one that answers "in lockdown".
    struct Boxes: BoxesProviding {
        static let lockdownBoxID: Int64 = 3

        private static func box(_ id: Int64, _ name: String, live: Int, email: String, percent: Int,
                                protected: Bool, locked: BoxLock?) -> DeviceDTO {
            let gigabyte: Int64 = 1024 * 1024 * 1024
            let now = Date()
            let capacity = BoxCapacity(
                liveSessions: live,
                limitLines: [LimitLine(id: BoxAllowances.allModelsLineID, label: "Week (all models)", percent: percent,
                                       resetsAt: now.addingTimeInterval(3 * 86_400))],
                accountEmail: email, disk: BoxDisk(freeBytes: 47 * gigabyte, totalBytes: 145 * gigabyte),
                limitsAsOf: now.addingTimeInterval(-120),
                defaults: BoxResolvedDefaults(agent: "claude", model: "opus", effort: nil))
            return DeviceDTO(id: id, kind: "agent", name: name, createdAt: 0, cursor: 0, lag: 0, lastSeenAt: nil,
                             isSelf: false, connected: true,
                             status: BoxStatus(reportedAt: now.addingTimeInterval(-120), capacity: capacity),
                             isProtected: protected, locked: locked)
        }

        func devices() async throws -> [DeviceDTO] {
            [
                Self.box(1, "box-a", live: 2, email: "alice@example.com", percent: 21, protected: true,
                         locked: BoxLock(until: nil)),
                Self.box(2, "box-b", live: 1, email: "alice@example.com", percent: 21, protected: false,
                         locked: BoxLock(until: Date().addingTimeInterval(24 * 60 - 20))),
                Self.box(Self.lockdownBoxID, "box-c", live: 0, email: "bob@example.com", percent: 48, protected: true,
                         locked: BoxLock(until: nil)),
                Self.box(4, "box-d", live: 3, email: "bob@example.com", percent: 48, protected: false, locked: nil),
            ]
        }

        func roster() async throws -> RosterSnapshot { RosterSnapshot(wakeableBoxes: [], sessionsByBox: [:]) }

        func agentRequest(agentDeviceID: Int64, method: String, paramsData: Data) async throws -> RPCReply {
            agentDeviceID == Self.lockdownBoxID ? .failure(code: "lockdown", detail: nil) : .ok(resultData: Data("{}".utf8))
        }

        func boxStatusUpdates() -> AsyncStream<(deviceID: Int64, status: BoxStatus)> { AsyncStream { _ in } }
        func connectionStates() -> AsyncStream<SyncConnectionState> { AsyncStream { _ in } }
    }

    final class NoCapacityCache: BoxCapacityCaching {
        func loadAll() -> [Int64: CachedBoxCapacity] { [:] }
        func save(_ capacity: BoxCapacity, for agentID: Int64, at capturedAt: Date) {}
        func prune(keeping agentIDs: Set<Int64>) {}
    }

    /// The boxes view model over `Boxes`, loaded, with box-c having
    /// answered "in lockdown" to an unlock.
    @MainActor
    static func boxesViewModel() async -> BoxesViewModel {
        let viewModel = BoxesViewModel(api: Boxes(), capacityCache: NoCapacityCache(), pollSleep: { try? await Task.sleep(for: .seconds(3600)) })
        viewModel.approvalSigner = { _ in SignedApproval(statement: "{}", signature: "s") }
        await viewModel.load()
        if let locked = viewModel.rows().first(where: { $0.id == Boxes.lockdownBoxID }) {
            await viewModel.unlock(locked.device, minutes: 30)
        }
        return viewModel
    }
}
