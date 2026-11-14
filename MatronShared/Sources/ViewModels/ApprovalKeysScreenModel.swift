import Foundation
import Observation
import MatronJournal

/// Settings ▸ Approval keys: this device's key and fingerprint, the
/// account's keys, the requests waiting to be approved, and the forms that
/// add and remove keys. The words live here so the iPhone and the Mac say
/// the same thing.
@Observable @MainActor
public final class ApprovalKeysScreenModel {
    public static let title = "Approval keys"
    public static let intro = "An approval key lives in this device's secure hardware and signs dangerous actions after Face ID or Touch ID. A stolen password or session can't approve them."
    public static let pinningNote = "A protected box trusts only the keys pinned on it. Pin a key from the fingerprint its own device shows here, never from this list alone."

    /// One key of the account, as a row.
    public struct KeyRow: Identifiable, Equatable {
        public let key: ApprovalKeyDTO
        public let isThisDevice: Bool
        /// "Added with password and code · 12 Nov 2026".
        public let detail: String
        /// "Not attached to a signed-in device", "Removed 13 Nov 2026".
        public let state: String?
        public var id: String { key.keyID }
        public var isLive: Bool { key.isLive }
    }

    /// The form in front of the screen.
    public enum Form: Equatable, Identifiable {
        /// Password and code, to set this device's key up.
        case setUp
        /// Password and code, to remove a key this device cannot sign for.
        case remove(ApprovalKeyDTO)

        public var id: String {
            switch self {
            case .setUp: return "setup"
            case .remove(let key): return "remove-" + key.keyID
            }
        }
    }

    public let center: ApprovalCenter
    public var form: Form?
    public var password = ""
    public var code = ""
    public private(set) var isBusy = false
    /// What went wrong, under the section it belongs to (or in the form).
    public private(set) var error: String?

    private let dateFormatter: DateFormatter

    public init(center: ApprovalCenter, locale: Locale = .current, timeZone: TimeZone = .current) {
        self.center = center
        dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = timeZone
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
    }

    // MARK: This device

    /// The headline for this device's state.
    public var statusTitle: String {
        switch center.status {
        case .unknown: return center.loadError == nil ? "Checking…" : "Couldn't read the account's keys"
        case .disabled: return "Not available on this server"
        case .unavailable: return "This device can't hold a key"
        case .noAccountKey: return "No approval key yet"
        case .noDeviceKey: return "This device has no key"
        case .waitingForApproval: return "Waiting for another device to approve"
        case .needsAttach: return "Key needs re-attaching"
        case .ready: return "This device can approve"
        case .revoked: return "This device's key was removed"
        case .invalidated: return "This device's key no longer works"
        }
    }

    public var statusDetail: String {
        let method = center.method ?? "Face ID or Touch ID"
        switch center.status {
        case .unknown: return center.loadError ?? ""
        case .disabled: return "The server needs a public address set before approval keys can be used."
        case .unavailable(let advice): return advice
        case .noAccountKey:
            return "Dangerous actions are approved with a tap for now. Set up a key and they will need \(method) on a device that holds one."
        case .noDeviceKey:
            return "The account has an approval key on another device. Until this device has one too, it can't approve step-up questions or account changes."
        case .waitingForApproval:
            return "On a device that has a key, open Settings ▸ Approval keys, check it shows the fingerprint below for this device, and approve. The request lasts ten minutes."
        case .needsAttach:
            return "This device signed in again since its key was added. Re-attach the key with \(method) before approving anything."
        case .ready:
            return "Dangerous actions ask for \(method) and are signed by this device's key."
        case .revoked:
            return "A removed key can't be added back. Set up a new one."
        case .invalidated:
            return "Its \(method) set-up changed since the key was made, which destroys the key. Set up a new one."
        }
    }

    public var statusSymbol: String {
        switch center.status {
        case .ready: return "checkmark.shield.fill"
        case .needsAttach, .waitingForApproval: return "clock.badge.exclamationmark"
        case .revoked, .invalidated: return "xmark.shield"
        case .unknown, .disabled, .unavailable: return "shield.slash"
        case .noAccountKey, .noDeviceKey: return "shield"
        }
    }

    /// The fingerprint to show for this device: its key's, once it has one
    /// that is enrolled or waiting.
    public var fingerprint: String? {
        switch center.status {
        case .ready, .needsAttach, .waitingForApproval: return center.deviceFingerprint
        default: return nil
        }
    }

    public var canSetUp: Bool {
        switch center.status {
        case .noAccountKey, .noDeviceKey, .revoked, .invalidated, .waitingForApproval: return true
        default: return false
        }
    }

    /// "Ask another device" is offered when the account already has a key
    /// some device could approve with.
    public var canAskAnotherDevice: Bool {
        switch center.status {
        case .noDeviceKey, .revoked, .invalidated: return center.accountHasKey
        default: return false
        }
    }

    public var canAttach: Bool { center.status == .needsAttach }

    /// The one-line summary under the Settings row.
    public var summary: String {
        switch center.status {
        case .ready: return "This device can approve"
        case .needsAttach: return "Needs re-attaching"
        case .waitingForApproval: return "Waiting for approval"
        case .noAccountKey: return "Not set up"
        case .noDeviceKey: return "Not on this device"
        case .revoked, .invalidated: return "Needs a new key"
        case .unavailable: return "Not on this device"
        case .disabled: return "Not available"
        case .unknown: return ""
        }
    }

    /// The Settings row is marked when the user should act on it.
    public var needsAttention: Bool {
        switch center.status {
        case .needsAttach, .revoked, .invalidated, .noDeviceKey: return true
        default: return !(center.state?.requests.isEmpty ?? true) && center.canSign
        }
    }

    // MARK: Lists

    public var requests: [ApprovalKeyRequestDTO] {
        // This device's own request is shown as its status, not as
        // something to approve.
        (center.state?.requests ?? []).filter { $0.keyID != center.deviceKeyID }
    }

    public var rows: [KeyRow] {
        (center.state?.keys ?? []).map { key in
            let how: String
            switch key.enrolledVia {
            case .password: how = "Added with password and code"
            case .device: how = "Approved from another device"
            case nil: how = "Added"
            }
            let state: String?
            if let revokedAt = key.revokedAt {
                state = "Removed \(dateFormatter.string(from: revokedAt))"
            } else if key.deviceID == nil {
                state = "Not attached to a signed-in device"
            } else {
                state = nil
            }
            return KeyRow(key: key, isThisDevice: key.keyID == center.deviceKeyID,
                          detail: "\(how) · \(dateFormatter.string(from: key.createdAt))", state: state)
        }
    }

    // MARK: Actions

    public func load() async {
        await center.refresh()
    }

    /// Opens the password-and-code form to set this device's key up.
    public func beginSetUp() {
        clearSecrets()
        error = nil
        form = .setUp
    }

    /// Removes a key: signed by this device when it can, else by password
    /// and code (its form opens).
    public func remove(_ key: ApprovalKeyDTO) async {
        guard center.canSign else {
            clearSecrets()
            error = nil
            form = .remove(key)
            return
        }
        await run { try await self.center.revoke(key) }
    }

    public var canSubmitForm: Bool { !isBusy && !password.isEmpty && code.count >= 6 }

    /// The form's button. True when it is done and the form should close.
    @discardableResult
    public func submitForm() async -> Bool {
        guard let form, canSubmitForm else { return false }
        let (password, code) = (self.password, self.code.trimmingCharacters(in: .whitespaces))
        let done = await run {
            switch form {
            case .setUp:
                if self.center.status == .revoked || self.center.status == .invalidated {
                    await self.center.discardDeviceKey()
                }
                try await self.center.enrol(password: password, code: code)
            case .remove(let key):
                try await self.center.revoke(key, password: password, code: code)
            }
        }
        // Whatever happened, the password is typed again.
        self.password = ""
        self.code = ""
        if done { self.form = nil }
        return done
    }

    public func closeForm() {
        form = nil
        clearSecrets()
        error = nil
    }

    public func askAnotherDevice() async {
        await run {
            if self.center.status == .revoked || self.center.status == .invalidated {
                await self.center.discardDeviceKey()
            }
            try await self.center.requestFromAnotherDevice()
        }
    }

    public func approve(_ request: ApprovalKeyRequestDTO) async {
        await run { try await self.center.approve(request) }
    }

    public func attach() async {
        await run { try await self.center.attach() }
    }

    @discardableResult
    private func run(_ work: @escaping () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await work()
            return true
        } catch ApprovalKeyFailure.cancelled {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func clearSecrets() {
        password = ""
        code = ""
    }
}
