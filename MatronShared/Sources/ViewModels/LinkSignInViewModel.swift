import Foundation
import MatronAuth
import MatronJournal
import MatronModels

/// The claimant slice of `JournalAPI` (both calls unauthenticated),
/// extracted so the view model tests against a fake.
public protocol LinkClaiming: Sendable {
    func linkClaim(code: String, deviceName: String) async throws -> LinkClaim
    func linkPoll(claimToken: String) async throws -> LinkPollResult
}

extension JournalAPI: LinkClaiming {}

/// Signs a NEW device in from a link code — the claimant half of QR
/// device-link login. Two entry points: `handleScanned` (camera, full
/// `matron://link` URI) and `submitManual` (typed server URL + code).
/// Both converge on claim → poll → build the same `UserSession` shape
/// password login builds (`userID` = the server-returned username) →
/// `auth.persist` → `.signedIn`, which the host view forwards to the
/// normal `onSignedIn` path.
@Observable @MainActor
public final class LinkSignInViewModel {
    public enum Phase: Equatable {
        case idle
        case claiming
        case waitingForApproval
        case error(String)
        case signedIn(UserSession)
    }

    /// Manual path. On iOS the sign-in form's server field seeds this; on
    /// Mac the code field lives on the sign-in form next to it.
    public var serverURL: String = ""
    /// Auto-formatted as `XXXX-XXXX` while typing, like PairingViewModel.
    public var codeInput: String = "" {
        didSet {
            let formatted = PairingCode.display(codeInput)
            if formatted != codeInput {
                codeInput = formatted // re-enters didSet once; equality stops it
            }
        }
    }

    public private(set) var phase: Phase = .idle

    private let auth: AuthService
    private let deviceDisplayName: String
    private let apiFactory: @Sendable (URL) -> any LinkClaiming
    private let pollInterval: Duration
    private let errorPollInterval: Duration
    private var pollTask: Task<Void, Never>?

    /// `apiFactory` exists for tests; the default builds a real JournalAPI
    /// against whatever server the QR names.
    public init(auth: AuthService, deviceDisplayName: String,
                apiFactory: (@Sendable (URL) -> any LinkClaiming)? = nil,
                pollInterval: Duration = .seconds(2),
                errorPollInterval: Duration = .seconds(5)) {
        self.auth = auth
        self.deviceDisplayName = deviceDisplayName
        self.apiFactory = apiFactory ?? { JournalAPI(serverURL: $0) }
        self.pollInterval = pollInterval
        self.errorPollInterval = errorPollInterval
    }

    public func handleScanned(_ payload: String) async {
        do {
            let (server, code) = try LinkURI.parse(payload)
            await claim(server: server, code: code)
        } catch LinkURI.ParseError.unsupportedVersion {
            phase = .error("This QR code needs a newer version of Matron.")
        } catch {
            phase = .error("Not a Matron sign-in code.")
        }
    }

    public func submitManual() async {
        let raw = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, PairingCode.isPlausible(codeInput) else { return }
        let url: URL
        do {
            url = try ServerURLValidator.normalize(raw)
        } catch {
            phase = .error("That doesn't look like a valid server URL.")
            return
        }
        await claim(server: url, code: PairingCode.display(codeInput))
    }

    /// Back out: stop polling and return to the sign-in form. The show side
    /// still sees `claimed` and can deny or let the code expire.
    public func cancel() {
        pollTask?.cancel()
        pollTask = nil
        phase = .idle
    }

    private func claim(server: URL, code: String) async {
        guard phase != .claiming, phase != .waitingForApproval else { return }
        phase = .claiming
        let api = apiFactory(server)
        do {
            let claim = try await api.linkClaim(code: code, deviceName: deviceDisplayName)
            phase = .waitingForApproval
            startPolling(api: api, server: server, claimToken: claim.claimToken)
        } catch JournalAPIError.conflict {
            phase = .error("This code was already used. Generate a new one on your signed-in device.")
        } catch JournalAPIError.notFound {
            phase = .error("Code not recognized or expired. Show a fresh QR code and try again.")
        } catch JournalAPIError.rateLimited {
            phase = .error("Too many attempts — try again in a minute.")
        } catch {
            phase = .error("Couldn't reach the server — try again.")
        }
    }

    private func startPolling(api: any LinkClaiming, server: URL, claimToken: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            var interval = self.pollInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                do {
                    switch try await api.linkPoll(claimToken: claimToken) {
                    case .pending:
                        interval = self.pollInterval
                    case .denied:
                        self.phase = .error("Sign-in was denied on the other device.")
                        return
                    case .approved(let approval):
                        let session = UserSession(userID: approval.username,
                                                  deviceID: String(approval.deviceID),
                                                  homeserverURL: server,
                                                  accessToken: approval.token)
                        do {
                            try self.auth.persist(session)
                        } catch {
                            self.phase = .error("Signed in, but couldn't save the session — try again.")
                            return
                        }
                        self.phase = .signedIn(session)
                        return
                    }
                } catch JournalAPIError.notFound {
                    self.phase = .error("Sign-in expired. Scan again.")
                    return
                } catch {
                    interval = self.errorPollInterval // network loss: back off, keep trying
                }
            }
        }
    }
}
