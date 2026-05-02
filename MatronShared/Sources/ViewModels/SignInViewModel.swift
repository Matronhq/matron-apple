import Foundation
import MatronAuth
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

    public var serverURL: String = ""
    public var username: String = ""
    public var password: String = ""
    public private(set) var state: State = .idle

    private let auth: AuthService
    private let deviceDisplayName: String

    /// `deviceDisplayName` is platform-specific — "Matron iOS" from the iOS
    /// app, "Matron Mac" from the Mac app — so the ViewModel itself stays
    /// target-agnostic. Each App struct passes its own value.
    public init(auth: AuthService, deviceDisplayName: String) {
        self.auth = auth
        self.deviceDisplayName = deviceDisplayName
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
        } catch let error as AuthError {
            state = .error(message(for: error))
        } catch {
            state = .error("Unexpected error: \(error.localizedDescription)")
        }
    }

    private func message(for error: AuthError) -> String {
        switch error {
        case .invalidServerURL: return "That doesn't look like a valid server URL."
        case .serverUnreachable: return "Couldn't reach that server."
        case .ssoNotSupported: return "SSO is not supported by this server."
        case .invalidCredentials: return "Invalid credentials."
        case .unexpected(let s): return s
        }
    }
}
