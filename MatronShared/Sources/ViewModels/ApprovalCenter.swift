import Foundation
import Observation
import MatronAuth
import MatronJournal

/// The one place that knows the account's approval keys and this device's
/// own, and turns "sign this" into `{statement, signature}`: it reads the
/// keys, shows the user what is being approved (`prompt`, drawn by the
/// confirm sheet), and only once they confirm fetches a nonce and asks the
/// device's key, behind Face ID or Touch ID, to sign.
///
/// View models and `JournalAPI` ask it through `sign`; none of them builds
/// a statement.
@Observable @MainActor
public final class ApprovalCenter {
    /// Where this device stands.
    public enum Status: Equatable, Sendable {
        /// The keys have not been read yet.
        case unknown
        /// The server has approval keys switched off.
        case disabled
        /// This device cannot hold a key; `advice` says what to do instead.
        case unavailable(advice: String)
        /// No key on the account: nothing needs a signature yet.
        case noAccountKey
        /// The account has a key; this device has none and cannot approve.
        case noDeviceKey
        /// This device asked for its key to be added and waits for a device
        /// that has one to approve it.
        case waitingForApproval
        /// This device holds a key the account has, but it is not attached
        /// to this sign-in (the device signed in again). It must be
        /// attached before it signs anything else.
        case needsAttach
        case ready
        /// This device's key was removed from the account.
        case revoked
        /// This device's key was destroyed by a change to its Face ID or
        /// Touch ID set-up.
        case invalidated
    }

    /// What the confirm sheet shows.
    public struct Prompt: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let request: ApprovalRequest
        /// "Face ID" or "Touch ID".
        public let method: String
        /// The fingerprint of the key that will sign.
        public let fingerprint: String
        /// This device's key is re-attached to the sign-in first, which
        /// asks for Face ID or Touch ID once more.
        public let attachesFirst: Bool
    }

    public private(set) var state: ApprovalKeysState?
    public private(set) var status: Status = .unknown
    /// The request waiting for the user's confirmation, if any.
    public private(set) var prompt: Prompt?
    /// True from the user's confirmation until the signature is made.
    public private(set) var isSigning = false
    /// Why the last try at signing failed, shown on the sheet, which stays
    /// up for another try.
    public private(set) var promptError: String?
    /// The fingerprint of this device's key, enrolled or not.
    public private(set) var deviceFingerprint: String?
    /// The key id of this device's key.
    public private(set) var deviceKeyID: String?
    /// The last read of the keys failed with this.
    public private(set) var loadError: String?

    private let api: any ApprovalKeysProviding
    private let keys: any ApprovalKeyProviding
    private let store: ApprovalKeyStore
    private let user: String
    private let deviceID: Int64?
    private let deviceName: String
    private let now: @Sendable () -> Date

    private var decision: CheckedContinuation<Bool, Never>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - user: the account's name, as signed in with.
    ///   - deviceID: this sign-in's device id.
    ///   - deviceName: what this device's key is called on the account.
    public init(api: any ApprovalKeysProviding, keys: any ApprovalKeyProviding, store: ApprovalKeyStore,
                user: String, deviceID: Int64?, deviceName: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.keys = keys
        self.store = store
        self.user = user
        self.deviceID = deviceID
        self.deviceName = String(deviceName.prefix(40))
        self.now = now
        noteDeviceKey(store.load())
    }

    /// "Face ID" or "Touch ID", when this device can hold a key.
    public var method: String? { keys.availability.method }

    /// Whether a guarded request will need a signature: the account has a
    /// key. False until the keys have been read.
    public var accountHasKey: Bool { state?.hasActiveKey ?? false }

    /// Whether this device can sign right now (after an attach, if needed).
    public var canSign: Bool { status == .ready || status == .needsAttach }

    // MARK: Reading

    /// Reads the account's keys. Called at launch, after sign-in, when the
    /// keys screen opens and before every signature.
    public func refresh() async {
        _ = try? await load()
    }

    @discardableResult
    private func load() async throws -> ApprovalKeysState {
        do {
            let fresh = try await api.approvalKeys()
            state = fresh
            loadError = nil
            recompute()
            return fresh
        } catch {
            loadError = error.localizedDescription
            throw error
        }
    }

    private func noteDeviceKey(_ stored: StoredApprovalKey?) {
        deviceKeyID = stored?.keyID
        deviceFingerprint = stored.map { ApprovalKeyEncoding.fingerprint(keyID: $0.keyID) }
    }

    private func recompute() {
        let stored = store.load()
        noteDeviceKey(stored)
        guard let state else { status = .unknown; return }
        guard state.enabled else { status = .disabled; return }
        if let stored, let listed = state.key(stored.keyID) {
            if !listed.isLive {
                status = .revoked
            } else if (try? keys.signingKey(for: stored)) == nil {
                status = .invalidated
            } else {
                status = listed.deviceID == deviceID && deviceID != nil ? .ready : .needsAttach
            }
            return
        }
        if let stored, state.requests.contains(where: { $0.keyID == stored.keyID }) {
            status = .waitingForApproval
            return
        }
        if case .unavailable(let advice) = keys.availability {
            status = .unavailable(advice: advice)
            return
        }
        status = state.hasActiveKey ? .noDeviceKey : .noAccountKey
    }

    // MARK: Signing

    /// Signs `request` after the user confirms it. Returns nil when the
    /// account has no approval key: the request then goes unsigned, as it
    /// always did. Throws `ApprovalKeyFailure.cancelled` when the user
    /// backs out, `ApprovalError` when the account has a key and this
    /// device cannot sign, and the read's own error when the keys cannot
    /// be read (never silently unsigned).
    public func sign(_ request: ApprovalRequest) async throws -> SignedApproval? {
        let state = try await load()
        guard state.hasActiveKey else { return nil }
        guard state.enabled, let journal = state.journal else { throw ApprovalError.disabled }
        guard let stored = store.load(), let listed = state.key(stored.keyID) else {
            throw ApprovalError.noKeyOnThisDevice
        }
        guard listed.isLive else { throw ApprovalError.keyRevoked }
        let key = try keys.signingKey(for: stored)

        await takeTurn()
        defer { endTurn() }

        var attached = listed.deviceID == deviceID && deviceID != nil
        promptError = nil
        prompt = Prompt(id: UUID(), request: request, method: method ?? "Face ID",
                        fingerprint: ApprovalKeyEncoding.fingerprint(keyID: stored.keyID), attachesFirst: !attached)
        defer {
            prompt = nil
            promptError = nil
            isSigning = false
        }
        while true {
            let confirmed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                decision = continuation
            }
            guard confirmed else { throw ApprovalKeyFailure.cancelled }
            isSigning = true
            promptError = nil
            do {
                if !attached {
                    try await attach(key: key, journal: journal)
                    attached = true
                }
                let approval = try await statement(request, key: key, journal: journal)
                return approval
            } catch ApprovalKeyFailure.cancelled {
                // They backed out of Face ID, not of the request: the
                // sheet stays, for another try or its own Cancel.
                isSigning = false
            } catch {
                isSigning = false
                promptError = error.localizedDescription
                if case ApprovalKeyFailure.invalidated = error { recompute() }
            }
        }
    }

    /// The confirm sheet's primary button.
    public func confirm() {
        guard let decision else { return }
        self.decision = nil
        decision.resume(returning: true)
    }

    /// The confirm sheet's Cancel, and its dismissal.
    public func cancel() {
        guard let decision else { return }
        self.decision = nil
        decision.resume(returning: false)
    }

    private func statement(_ request: ApprovalRequest, key: any ApprovalSigningKey, journal: String) async throws -> SignedApproval {
        let nonce = try await api.approvalNonce()
        let statement = ApprovalStatement(kind: request.kind, journal: journal, user: user, keyID: key.keyID,
                                          nonce: nonce.nonce, signedAt: Int64(now().timeIntervalSince1970 * 1000),
                                          subject: request.subject)
        return try await statement.signed(by: key, reason: Self.reason(for: request))
    }

    private func attach(key: any ApprovalSigningKey, journal: String) async throws {
        let request = ApprovalRequest(kind: .account, subject: ApprovalSubjects.attachKey(keyID: key.keyID),
                                      headline: "Re-attach this device's approval key")
        let approval = try await statement(request, key: key, journal: journal)
        _ = try await api.attachApprovalKey(approval: approval)
        _ = try? await load()
    }

    /// What the system's Face ID or Touch ID prompt says.
    static func reason(for request: ApprovalRequest) -> String {
        if let button = request.button { return "\(button): \(request.headline)" }
        return request.headline
    }

    private func takeTurn() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func endTurn() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: Keys

    /// The key this device will enrol: one made earlier that the account
    /// has never seen (a refused try), else a new one.
    private func keyToEnrol() throws -> StoredApprovalKey {
        if let stored = store.load(), state?.key(stored.keyID) == nil, (try? keys.signingKey(for: stored)) != nil {
            return stored
        }
        let made = try keys.create()
        try store.save(made)
        noteDeviceKey(made)
        return made
    }

    /// Sets this device's key up with the password and a code from the
    /// authenticator: the first key on an account, and the way back when
    /// no device with a key is left.
    public func enrol(password: String, code: String) async throws {
        let stored = try keyToEnrol()
        do {
            _ = try await api.enrolApprovalKey(publicKey: ApprovalKeyEncoding.base64URL(stored.publicKey),
                                               name: deviceName, password: password, code: code)
        } catch {
            // `key_exists`: this key was enrolled before and removed, and
            // can never be added again. Drop it, so the next try makes a
            // new one. Any other refusal keeps the key for the next try.
            if case ApprovalKeyError.keyExists = error { store.delete() }
            await refresh()
            throw error
        }
        await refresh()
    }

    /// Asks for this device's key to be added by a device that already has
    /// one. The other device shows this key's fingerprint; the user
    /// compares the two and approves there, within ten minutes.
    public func requestFromAnotherDevice() async throws {
        let stored = try keyToEnrol()
        do {
            _ = try await api.requestApprovalKey(publicKey: ApprovalKeyEncoding.base64URL(stored.publicKey), name: deviceName)
        } catch {
            // `key_exists`: this key was enrolled before and removed, and
            // can never be added again. Drop it, so the next try makes a
            // new one. Any other refusal keeps the key for the next try.
            if case ApprovalKeyError.keyExists = error { store.delete() }
            await refresh()
            throw error
        }
        await refresh()
    }

    /// Approves another device's request, signing for the fingerprint the
    /// user has compared.
    public func approve(_ request: ApprovalKeyRequestDTO) async throws {
        guard let approval = try await sign(ApprovalRequest(
            kind: .account, subject: ApprovalSubjects.enrolKey(keyID: request.keyID),
            headline: "Add an approval key for \(request.name)",
            detail: "Check that \(request.name) shows the fingerprint \(request.fingerprint). Once added, that device can approve dangerous actions."))
        else { throw ApprovalError.noKeyOnThisDevice }
        _ = try await api.approveApprovalKeyRequest(id: request.id, approval: approval)
        await refresh()
    }

    /// Removes a key with this device's signature. A removed key can never
    /// be added again; when it is this device's own, it is deleted.
    public func revoke(_ key: ApprovalKeyDTO) async throws {
        guard let approval = try await sign(ApprovalRequest(
            kind: .account, subject: ApprovalSubjects.revokeKey(keyID: key.keyID),
            headline: "Remove the approval key \(key.name)",
            detail: "Fingerprint \(key.fingerprint). It will no longer be able to approve anything, and can't be added back."))
        else { throw ApprovalError.noKeyOnThisDevice }
        try await api.revokeApprovalKey(keyID: key.keyID, approval: approval)
        finishRevoke(key)
        await refresh()
    }

    /// Removes a key with the password and a code, for when this device
    /// has no key to sign with (the only keyed phone is lost).
    public func revoke(_ key: ApprovalKeyDTO, password: String, code: String) async throws {
        try await api.revokeApprovalKey(keyID: key.keyID, password: password, code: code)
        finishRevoke(key)
        await refresh()
    }

    private func finishRevoke(_ key: ApprovalKeyDTO) {
        if store.load()?.keyID == key.keyID { store.delete() }
    }

    /// Re-attaches this device's key to the sign-in, on its own (the keys
    /// screen's button). `sign` does the same before its first signature.
    public func attach() async throws {
        let state = try await load()
        guard state.enabled, let journal = state.journal else { throw ApprovalError.disabled }
        guard let stored = store.load(), let listed = state.key(stored.keyID) else { throw ApprovalError.noKeyOnThisDevice }
        guard listed.isLive else { throw ApprovalError.keyRevoked }
        guard listed.deviceID != deviceID || deviceID == nil else { return }
        try await attach(key: try keys.signingKey(for: stored), journal: journal)
    }

    /// Forgets a key this device holds that the account no longer takes
    /// (removed, or destroyed by a biometric change), so a new one can be
    /// set up.
    public func discardDeviceKey() async {
        store.delete()
        await refresh()
        recompute()
    }
}

public extension ApprovalCenter {
    /// The signer `JournalAPI` and the view models call.
    nonisolated var signer: ApprovalSigner {
        { [weak self] request in
            guard let self else { return nil }
            return try await self.sign(request)
        }
    }
}
