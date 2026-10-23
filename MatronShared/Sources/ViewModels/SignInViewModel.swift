import Foundation
import MatronAuth
import MatronJournal
import MatronModels

@Observable
@MainActor
public final class SignInViewModel {
    public enum State: Equatable {
        case idle
        case busy
        case error(String)
        case signedIn(UserSession)
    }

    // Deliberately empty: shipping a pre-filled default (formerly a dead
    // placeholder host) meant the field looked already-answered — App Review
    // signed in over it and hit "Couldn't reach that server."
    /// Which screen of the sign-in the user is on. Everything after
    /// `.password` is the two-factor step the server asked for.
    public enum Step: Equatable {
        case password
        /// Enter an authenticator code (or a recovery code).
        case code(TwoFactorChallenge)
        /// Set up an authenticator before signing in. `setup` is nil while
        /// the new secret is on its way.
        case enrol(TwoFactorChallenge, setup: TwoFactorSetup?)
        /// Enrolment finished: show the recovery codes this once, then sign in.
        case recoveryCodes(UserSession, codes: [String])
        /// Signed in with a recovery code: say how many are left, then sign in.
        case usedRecoveryCode(UserSession, left: Int?)
    }

    public var serverURL: String = "" {
        didSet {
            // "Forgot password?" was answered for the old server, not this
            // one: off until `checkPasswordReset` asks the new one.
            if serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
                != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) {
                forgotPasswordAvailable = false
                passwordResetServer = nil
            }
        }
    }
    public var username: String = ""
    public var password: String = ""
    public private(set) var state: State = .idle
    public private(set) var step: Step = .password
    /// The two-factor code field: six digits, or a recovery code when
    /// `usesRecoveryCode` is on.
    public var code: String = ""
    public var usesRecoveryCode = false
    /// Why the user is looking at the sign-in screen, when it wasn't their
    /// own doing — shown above the form. `nil` for a plain sign-in.
    public let notice: String?

    // MARK: Forgot password

    /// Where the "Forgot password?" form is.
    public enum ForgotPasswordState: Equatable {
        case editing
        case sending
        /// The journal took the request: the form shows `forgotPasswordSent`
        /// and "Back to sign in" only.
        case sent
        case error(String)
    }

    /// Whether to show "Forgot password?" under the password field: only
    /// once the journal at the typed server has said it mails reset links.
    public private(set) var forgotPasswordAvailable = false
    /// The "Forgot password?" sheet.
    public var isShowingForgotPassword = false
    /// "Username or email".
    public var forgotIdentifier = ""
    public private(set) var forgotState: ForgotPasswordState = .editing
    /// The server (as typed, trimmed) that said it mails reset links. A
    /// request only ever goes to this one.
    private var passwordResetServer: String?
    /// Bumped each time the form opens or closes, so an answer for a form
    /// since closed is dropped.
    private var forgotGeneration = 0

    public static let forgotLinkTitle = "Forgot password?"
    public static let forgotIdentifierLabel = "Username or email"
    public static let forgotSubmitTitle = "Send reset link"
    public static let forgotBackTitle = "Back to sign in"
    /// The same whether or not the account exists, so it reveals nothing.
    public static let forgotPasswordSent =
        "If that account has an email address, we've sent a link to reset its password. It works once, for 30 minutes."

    /// The notice shown after this device's credentials were revoked
    /// elsewhere and the app signed itself out.
    public static let signedOutRemotelyNotice =
        "This device was signed out from another device. Sign in again to continue."

    private let auth: AuthService
    private let deviceDisplayName: String

    /// `deviceDisplayName` is platform-specific — "Matron iOS" from the iOS
    /// app, "Matron Mac" from the Mac app — so the ViewModel itself stays
    /// target-agnostic. Each App struct passes its own value.
    public init(auth: AuthService, deviceDisplayName: String) {
        self.auth = auth
        self.deviceDisplayName = deviceDisplayName
        self.notice = nil
    }

    /// The sign-in screen after the app signed itself out because `session`
    /// was revoked elsewhere: shows `signedOutRemotelyNotice` and fills in
    /// the server and username the user was signed in with, so getting back
    /// in only takes the password.
    public init(auth: AuthService, deviceDisplayName: String, signedOutRemotely session: UserSession) {
        self.auth = auth
        self.deviceDisplayName = deviceDisplayName
        self.notice = Self.signedOutRemotelyNotice
        self.serverURL = session.homeserverURL.absoluteString
        self.username = session.userID
    }

    public func submit() async {
        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !username.isEmpty,
              !password.isEmpty else {
            return
        }
        state = .busy
        do {
            _ = try await auth.probe(serverURL)
            let url = try ServerURLValidator.normalize(serverURL)
            let session = try await auth.loginPassword(
                homeserverURL: url,
                username: username,
                password: password,
                initialDeviceDisplayName: deviceDisplayName
            )
            try auth.persist(session)
            state = .signedIn(session)
        } catch let AuthError.twoFactorRequired(challenge) {
            code = ""
            usesRecoveryCode = false
            step = .code(challenge)
            state = .idle
        } catch let AuthError.twoFactorEnrolmentRequired(challenge) {
            code = ""
            usesRecoveryCode = false
            step = .enrol(challenge, setup: nil)
            await loadEnrolment(challenge)
        } catch {
            fail(error)
        }
    }

    // MARK: Forgot password

    private var trimmedServerURL: String { serverURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedForgotIdentifier: String { forgotIdentifier.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Asks the journal at the typed server whether it mails reset links.
    /// The screens call it, debounced, as the server field changes; an
    /// answer for a server the user has since changed is dropped.
    public func checkPasswordReset() async {
        let asked = trimmedServerURL
        guard !asked.isEmpty else {
            forgotPasswordAvailable = false
            passwordResetServer = nil
            return
        }
        let available = await auth.passwordResetAvailable(asked)
        // A cancelled check (the screen restarted it) answers false for
        // want of an answer: keep what is shown.
        guard !Task.isCancelled, trimmedServerURL == asked else { return }
        forgotPasswordAvailable = available
        passwordResetServer = available ? asked : nil
    }

    /// "Forgot password?": the form starts with the username, if typed.
    public func openForgotPassword() {
        guard forgotPasswordAvailable else { return }
        forgotGeneration += 1
        forgotIdentifier = username.trimmingCharacters(in: .whitespacesAndNewlines)
        forgotState = .editing
        isShowingForgotPassword = true
    }

    /// "Back to sign in" (or the sheet dismissed).
    public func closeForgotPassword() {
        forgotGeneration += 1
        isShowingForgotPassword = false
        forgotIdentifier = ""
        forgotState = .editing
    }

    /// Whether "Send reset link" is on.
    public var canSendForgotPassword: Bool {
        switch forgotState {
        case .sending, .sent: return false
        case .editing, .error: return !trimmedForgotIdentifier.isEmpty
        }
    }

    /// "Send reset link". Only ever to the server that said it mails links,
    /// and only while that is still the server typed.
    public func submitForgotPassword() async {
        guard canSendForgotPassword, forgotPasswordAvailable,
              let server = passwordResetServer, server == trimmedServerURL,
              let url = try? ServerURLValidator.normalize(server)
        else { return }
        let generation = forgotGeneration
        forgotState = .sending
        do {
            try await auth.requestPasswordReset(homeserverURL: url, identifier: trimmedForgotIdentifier)
            guard forgotGeneration == generation else { return }
            forgotState = .sent
        } catch {
            guard forgotGeneration == generation else { return }
            if let error = error as? AuthError {
                forgotState = .error(message(for: error))
            } else {
                forgotState = .error("Unexpected error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Two-factor

    /// The code with what the user may type around it (spaces, dashes)
    /// left in; the server ignores those.
    public var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether the code field holds something worth sending: six digits,
    /// or a recovery code's 16 characters.
    public var codeIsComplete: Bool {
        let significant = trimmedCode.filter { $0.isLetter || $0.isNumber }
        if usesRecoveryCode { return significant.count >= 16 }
        return significant.count == 6 && significant.allSatisfy(\.isNumber)
    }

    /// Sends the code for the current step: verifying a sign-in, or
    /// confirming a new authenticator.
    public func submitCode() async {
        guard codeIsComplete else { return }
        if case .busy = state { return }
        // An answer that lands after the user went back to the password
        // (or on to another sign-in) is dropped: it must not sign them in.
        let sent = step
        switch sent {
        case .code(let challenge):
            state = .busy
            do {
                let result = try await auth.verifyTwoFactor(challenge, code: trimmedCode)
                guard step == sent else { return }
                if result.usedRecoveryCode {
                    step = .usedRecoveryCode(result.session, left: result.recoveryCodesLeft)
                    state = .idle
                } else {
                    try finish(result.session)
                }
            } catch {
                guard step == sent else { return }
                fail(error)
            }
        case .enrol(let challenge, setup: .some):
            state = .busy
            do {
                let enrolment = try await auth.finishTwoFactorEnrolment(challenge, code: trimmedCode)
                guard step == sent else { return }
                step = .recoveryCodes(enrolment.session, codes: enrolment.recoveryCodes)
                state = .idle
            } catch {
                guard step == sent else { return }
                fail(error)
            }
        default:
            return
        }
    }

    /// Fetches the enrolment secret again after a failure.
    public func retryEnrolment() async {
        guard case .enrol(let challenge, setup: nil) = step else { return }
        await loadEnrolment(challenge)
    }

    /// "I've saved these" / "Continue": the session the two-factor step
    /// produced is stored and the app moves on.
    public func continueSignedIn() {
        switch step {
        case .recoveryCodes(let session, _), .usedRecoveryCode(let session, _):
            do {
                try finish(session)
            } catch {
                fail(error)
            }
        default:
            return
        }
    }

    /// Leaves the two-factor step for the password form. Nothing is signed
    /// in: the server's ticket simply expires.
    public func cancelTwoFactor() {
        backToPassword(error: nil)
    }

    /// What the recovery-code screen says after a sign-in that spent one.
    public static func recoveryCodeWarning(left: Int?) -> String {
        let manage = "Make new ones in Settings → Security."
        guard let left else { return "You signed in with a recovery code. It can't be used again. \(manage)" }
        switch left {
        case 0: return "You signed in with your last recovery code. \(manage)"
        case 1: return "You signed in with a recovery code. You have 1 left. \(manage)"
        default: return "You signed in with a recovery code. You have \(left) left. \(manage)"
        }
    }

    /// The recovery codes as one block of text, for Copy and Share.
    public static func recoveryCodesText(_ codes: [String]) -> String {
        (["Matron recovery codes. Each one works once."] + codes).joined(separator: "\n")
    }

    private func loadEnrolment(_ challenge: TwoFactorChallenge) async {
        let sent = Step.enrol(challenge, setup: nil)
        state = .busy
        do {
            let setup = try await auth.startTwoFactorEnrolment(challenge)
            guard step == sent else { return }
            step = .enrol(challenge, setup: setup)
            state = .idle
        } catch {
            guard step == sent else { return }
            fail(error)
        }
    }

    private func finish(_ session: UserSession) throws {
        try auth.persist(session)
        code = ""
        password = ""
        state = .signedIn(session)
    }

    private func backToPassword(error: String?) {
        step = .password
        code = ""
        usesRecoveryCode = false
        password = ""
        state = error.map(State.error) ?? .idle
    }

    private func fail(_ error: Error) {
        guard let error = error as? AuthError else {
            state = .error("Unexpected error: \(error.localizedDescription)")
            return
        }
        switch error {
        case .wrongTwoFactorCode(canRetry: true):
            code = ""
            state = .error("Wrong code. Try again.")
        case .wrongTwoFactorCode(canRetry: false):
            backToPassword(error: "Too many wrong codes. Enter your password again.")
        case .twoFactorExpired:
            backToPassword(error: "That sign-in timed out. Enter your password again.")
        default:
            state = .error(message(for: error))
        }
    }

    private func message(for error: AuthError) -> String {
        switch error {
        case .invalidServerURL: return "That doesn't look like a valid server URL."
        case .serverUnreachable: return "Couldn't reach that server."
        case .ssoNotSupported: return "SSO is not supported by this server."
        case .invalidCredentials: return "Invalid credentials."
        case .twoFactorRequired, .twoFactorEnrolmentRequired: return "Two-factor sign-in is needed."
        case .wrongTwoFactorCode: return "Wrong code. Try again."
        case .twoFactorExpired: return "That sign-in timed out. Enter your password again."
        case .twoFactorUnavailable: return "Two-factor sign-in isn't available on this server right now."
        case .rateLimited: return "Too many requests. Try again in a few minutes."
        case .unexpected(let s): return s
        }
    }
}
