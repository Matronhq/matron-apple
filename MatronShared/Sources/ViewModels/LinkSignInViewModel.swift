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
    /// Bumped by every `cancel()` (mirrors `DeviceLinkViewModel`). The poll
    /// loop snapshots this and re-checks it after each `await`; a mismatch
    /// means a `cancel()` landed while a `linkPoll()` was in flight, so the
    /// stale response is abandoned before it can persist a session the user
    /// cancelled or flip `phase` to `.signedIn`.
    private var generation = 0

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
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        phase = .idle
    }

    private func claim(server: URL, code: String) async {
        // Already signed in: a second scan/manual submit must not restart
        // the state machine and overwrite the signed-in session.
        if case .signedIn = phase { return }
        guard phase != .claiming, phase != .waitingForApproval else { return }
        phase = .claiming
        // A cancel() (bumps generation) can land while linkClaim() is in
        // flight — reachable via the sign-in view's onDisappear when a
        // concurrent password sign-in completes. Snapshot here and re-check
        // after the await before any phase write / startPolling(), so the
        // resumed call can't resurrect .waitingForApproval or spawn an
        // orphan poll (startPolling() would snapshot the already-bumped
        // generation, so the poll-loop guard alone can't catch this).
        let claimGeneration = generation
        let api = apiFactory(server)
        do {
            let claim = try await api.linkClaim(code: code, deviceName: deviceDisplayName)
            guard claimGeneration == generation else { return }
            phase = .waitingForApproval
            startPolling(api: api, server: server, claimToken: claim.claimToken)
        } catch JournalAPIError.conflict {
            guard claimGeneration == generation else { return }
            phase = .error("This code was already used. Generate a new one on your signed-in device.")
        } catch JournalAPIError.notFound {
            guard claimGeneration == generation else { return }
            phase = .error("Code not recognized or expired. Show a fresh QR code and try again.")
        } catch JournalAPIError.rateLimited {
            guard claimGeneration == generation else { return }
            phase = .error("Too many attempts — try again in a minute.")
        } catch {
            guard claimGeneration == generation else { return }
            phase = .error("Couldn't reach the server — try again.")
        }
    }

    private func startPolling(api: any LinkClaiming, server: URL, claimToken: String) {
        pollTask?.cancel()
        let pollGeneration = generation
        pollTask = Task { [weak self] in
            guard let self else { return }
            var interval = self.pollInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, pollGeneration == self.generation else { return }
                do {
                    let result = try await api.linkPoll(claimToken: claimToken)
                    // A cancel() (bumps generation) can have landed while
                    // this linkPoll() was in flight; abandon before persist
                    // and before any phase write so a cancelled sign-in is
                    // never persisted or surfaced as .signedIn.
                    guard !Task.isCancelled, pollGeneration == self.generation else { return }
                    switch result {
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
