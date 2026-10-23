import Foundation
import Observation
import MatronJournal

/// One sheet of Settings → Security, from its button to its last screen:
///
/// - Set Up… and Change App…: password (and, changing app, a code from the
///   current one), then the QR code and the first code from the new app,
///   then the recovery codes, shown once.
/// - New Recovery Codes…: password and a code, then the new codes.
/// - Turn Off…: password and a code, then the sheet closes.
///
/// The words follow Matron Web's Settings → Security.
@Observable @MainActor
public final class TwoFactorSecurityFlowModel {
    public typealias Action = TwoFactorSettingsModel.Action

    public enum Step: Equatable {
        /// The password, and a current code where the action needs one.
        case confirm
        /// Set Up… / Change App…: scan the new secret, enter its first code.
        case scan(TwoFactorSetup)
        /// The recovery codes, shown this once.
        case recoveryCodes([String])
        /// Turned off: the sheet closes.
        case finished
    }

    public let action: Action
    public private(set) var step: Step = .confirm
    public private(set) var isBusy = false
    public private(set) var error: String?
    /// Set Up… only: how many other apps and browsers were signed out.
    public private(set) var signedOut = 0

    public var password = ""
    /// A code from the current app, or a recovery code: Change App…, New
    /// Recovery Codes… and Turn Off….
    public var currentCode = ""
    /// The first code from the new app.
    public var newCode = ""
    /// Set Up…: also sign out the user's other apps and browsers.
    public var signOutOthers = false
    /// The recovery codes' "I've saved these codes" check, which Done waits for.
    public var savedCodes = false

    private let api: any TwoFactorSettingsProviding

    public init(action: Action, api: any TwoFactorSettingsProviding) {
        self.action = action
        self.api = api
    }

    // MARK: Words

    public var title: String {
        switch action {
        case .setUp: return "Set Up Two-Factor"
        case .changeApp: return "Change Authenticator App"
        case .newRecoveryCodes: return "New Recovery Codes"
        case .turnOff: return "Turn Off Two-Factor"
        }
    }

    /// The paragraph above the password.
    public var intro: String {
        switch action {
        case .setUp:
            return "You'll need an authenticator app such as Google Authenticator or 1Password. Enter your password to start."
        case .changeApp:
            return "Enter your password and a code from your current app (or a recovery code). Your current app keeps working until the new one is confirmed."
        case .newRecoveryCodes:
            return "Your old recovery codes stop working as soon as the new set is made."
        case .turnOff:
            return "Signing in will take only your password again. Your recovery codes stop working."
        }
    }

    /// The label of the current-code field, or nil when Set Up… has none.
    public var currentCodeLabel: String? {
        switch action {
        case .setUp: return nil
        case .changeApp: return "Code from your current app"
        case .newRecoveryCodes, .turnOff: return "Code from your app (or a recovery code)"
        }
    }

    public static let newCodeLabel = "Code from the app"
    public static let signOutOthersLabel = "Also sign out my other browsers and apps (agent boxes stay connected)"
    public static let recoveryCodesNote =
        "Keep these somewhere safe, such as your password manager. Each one signs you in once if you lose your authenticator app. You won't see them again."
    public static let savedCodesLabel = "I've saved these codes"

    /// The confirm button of the current step.
    public var submitTitle: String {
        switch step {
        case .confirm:
            switch action {
            case .setUp, .changeApp: return "Continue"
            case .newRecoveryCodes: return "Make New Codes"
            case .turnOff: return "Turn Off"
            }
        case .scan: return "Turn On"
        case .recoveryCodes, .finished: return "Done"
        }
    }

    /// The submit button is the destructive kind: Turn Off.
    public var isDestructive: Bool { action == .turnOff && step == .confirm }

    /// The line above the recovery codes.
    public var successText: String? {
        guard case .recoveryCodes = step else { return nil }
        switch action {
        case .setUp:
            let base = "Two-factor sign-in is on."
            guard signedOut > 0 else { return base }
            return "\(base) Signed out \(signedOut) other \(signedOut == 1 ? "device" : "devices")."
        case .changeApp: return "Your new app is set up."
        case .newRecoveryCodes, .turnOff: return nil
        }
    }

    // MARK: State

    public var canSubmit: Bool {
        guard !isBusy else { return false }
        switch step {
        case .confirm:
            guard !password.isEmpty else { return false }
            return currentCodeLabel == nil || Self.isCode(currentCode, allowsRecoveryCode: true)
        case .scan: return Self.isCode(newCode, allowsRecoveryCode: false)
        case .recoveryCodes: return savedCodes
        case .finished: return false
        }
    }

    /// The sheet must not be swiped away while recovery codes are showing:
    /// they are never shown again.
    public var blocksDismissal: Bool {
        if case .recoveryCodes = step { return !savedCodes }
        return false
    }

    /// Six digits (spaces allowed), or with `allowsRecoveryCode` a recovery
    /// code: 16 letters and digits, dashes and spaces ignored.
    public nonisolated static func isCode(_ text: String, allowsRecoveryCode: Bool) -> Bool {
        let significant = text.filter { $0.isLetter || $0.isNumber }
        if significant.count == 6 && significant.allSatisfy(\.isNumber) { return true }
        return allowsRecoveryCode && significant.count >= 16
    }

    public func submit() async {
        guard canSubmit else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            switch step {
            case .confirm:
                try await confirm()
            case .scan:
                let result = try await api.enableTwoFactor(code: newCode, signOutOthers: signOutOthers)
                signedOut = result.signedOut
                step = .recoveryCodes(result.recoveryCodes)
            case .recoveryCodes, .finished:
                step = .finished
            }
        } catch {
            fail(error)
        }
    }

    private func confirm() async throws {
        let code = currentCodeLabel == nil ? nil : currentCode
        switch action {
        case .setUp, .changeApp:
            let setup = try await api.beginTwoFactorSetup(password: password, code: code)
            clearSecrets()
            step = .scan(setup)
        case .newRecoveryCodes:
            let codes = try await api.newTwoFactorRecoveryCodes(password: password, code: currentCode)
            clearSecrets()
            step = .recoveryCodes(codes)
        case .turnOff:
            try await api.disableTwoFactor(password: password, code: currentCode)
            clearSecrets()
            step = .finished
        }
    }

    private func fail(_ failure: Error) {
        error = failure.localizedDescription
        // The setup expired: back to the password, which starts a new one.
        if failure as? TwoFactorSettingsError == .noPendingSetup { step = .confirm }
        // A wrong code is never typed again as it was.
        currentCode = ""
        newCode = ""
    }

    private func clearSecrets() {
        password = ""
        currentCode = ""
    }
}
