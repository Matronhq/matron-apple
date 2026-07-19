import Foundation
import MatronJournal

/// The show-QR slice of `JournalAPI`, extracted so the view model tests
/// against a fake (same pattern as `DevicesProviding`).
public protocol DeviceLinking: Sendable {
    func linkStart() async throws -> LinkStart
    func linkStatus() async throws -> LinkStatus
    func linkApprove(code: String) async throws
    func linkDeny(code: String) async throws
}

extension JournalAPI: DeviceLinking {}

/// Drives the Settings → "Link a Device" screen: start a session, render
/// the QR, poll status, and on a claim show the approve card (claimant
/// name + IP — the mandatory confirm-tap of the design; scanning alone
/// never signs anything in).
///
/// Lifecycle: `start()` on appear, `stop()` on disappear. Status 404 while
/// on screen means the session expired — routine, so the QR silently
/// regenerates. Approve/deny are terminal; the approve side does not wait
/// for the claimant's final poll.
@Observable @MainActor
public final class DeviceLinkViewModel {
    public enum Phase: Equatable {
        case loading
        case showing(code: String)
        case claimed(deviceName: String, requesterIP: String)
        case approved
        case denied
        /// 404 on start: the server predates /link/*.
        case unsupported
        case error(String)
    }

    public private(set) var phase: Phase = .loading
    /// One-line banner above a regenerated QR ("Code expired — showing a
    /// fresh one") or under a failed tap ("Couldn't approve — try again.").
    public private(set) var noticeMessage: String?
    /// True while an approve/deny/offer round-trip is in flight; reentrant
    /// approve/deny taps are ignored and the poll loop skips regeneration
    /// to avoid racing the in-flight request.
    public private(set) var isSubmitting = false

    /// The full QR payload for the current code (nil unless `.showing`).
    public var qrPayload: String? {
        guard case .showing(let code) = phase else { return nil }
        return LinkURI.format(server: serverURL, code: code)
    }

    private let api: any DeviceLinking
    private let serverURL: URL
    private let relay: (any RelayRendezvousing)?
    private let pollInterval: Duration
    private let errorPollInterval: Duration
    private var pollTask: Task<Void, Never>?
    /// The active session's display code — what approve/deny send back as
    /// the belt-and-braces intent check.
    private var currentCode: String?
    /// Bumped by every `stop()`. `startSession()` snapshots this on entry
    /// and re-checks it after each `await`; a mismatch means a `stop()`
    /// landed while the session was starting (e.g. the view disappeared
    /// while a regenerate's `linkStart()` was in flight), so the stale
    /// session abandons instead of resurrecting `phase` and spawning a
    /// poll loop that `stop()` can no longer reach.
    private var generation = 0

    public init(api: any DeviceLinking, serverURL: URL,
                relay: (any RelayRendezvousing)? = nil,
                pollInterval: Duration = .seconds(2),
                errorPollInterval: Duration = .seconds(5)) {
        self.api = api
        self.serverURL = serverURL
        self.relay = relay
        self.pollInterval = pollInterval
        self.errorPollInterval = errorPollInterval
    }

    public func start() async {
        stop()
        noticeMessage = nil
        phase = .loading
        await startSession()
    }

    public func stop() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
    }

    public func approve() async {
        guard case .claimed = phase, !isSubmitting, let code = currentCode else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await api.linkApprove(code: code)
            stop()
            phase = .approved
        } catch JournalAPIError.notFound {
            noticeMessage = "Code expired — showing a fresh one"
            stop()
            await startSession()
        } catch JournalAPIError.conflict {
            // Nothing left to approve (raced expiry/replacement) — same
            // recovery as expiry: fresh code.
            noticeMessage = "Code expired — showing a fresh one"
            stop()
            await startSession()
        } catch {
            noticeMessage = "Couldn't approve — try again."
        }
    }

    public func deny() async {
        guard case .claimed = phase, !isSubmitting, let code = currentCode else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await api.linkDeny(code: code)
            stop()
            phase = .denied
        } catch JournalAPIError.notFound {
            stop()
            await startSession()
        } catch {
            noticeMessage = "Couldn't deny — try again."
        }
    }

    /// Settings → Link a Device → Scan tab: the signed-in phone scanned a
    /// signed-out device's `matron://rlink` QR. Offers THIS VM's live link
    /// session to the relay — start() already minted a session when the
    /// screen opened, and link/start replaces a starter's session, so
    /// minting another here would kill the code being offered. After a
    /// successful offer the desktop claims within seconds and the existing
    /// status poll flips to .claimed → the normal approve card.
    public func offerScanned(_ payload: String) async {
        guard let relay else { return }
        // A double-fired scan callback must not stack a second offer on
        // the one still in flight.
        guard !isSubmitting else { return }
        let gen = generation
        let rid: String
        do {
            let parsed = try RendezvousURI.parse(payload)
            rid = parsed.rid
        } catch RendezvousURI.ParseError.unsupportedVersion {
            noticeMessage = "This QR code needs a newer version of Matron."
            return
        } catch {
            noticeMessage = "Not a Matron link code."
            return
        }
        guard case .showing(let code) = phase else {
            switch phase {
            case .claimed, .approved, .denied:
                noticeMessage = "A link session is already in progress — finish it before linking another device."
            default:
                noticeMessage = "Still fetching a link code — try scanning again in a moment."
            }
            return
        }
        // Mirror approve()/deny()'s poll-inhibition: without this, a
        // 404-driven regeneration racing this await can replace the
        // session mid-offer, so the relay hands the desktop a code this
        // device can no longer claim.
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await relay.offerRendezvous(rid: rid, server: serverURL.absoluteString, code: code)
            guard gen == generation else { return }
            noticeMessage = "Sent — approve the request when it appears."
        } catch {
            guard gen == generation else { return }
            switch error as? RelayError {
            case .conflict: noticeMessage = "That code was already used by another device."
            case .notFound: noticeMessage = "That code expired — ask the computer to show a fresh one."
            default: noticeMessage = "Couldn't reach the Matron relay — try again."
            }
        }
    }

    private func startSession() async {
        let sessionGeneration = generation
        do {
            let started = try await api.linkStart()
            guard sessionGeneration == generation else { return } // superseded by a stop() — abandon silently
            currentCode = started.code
            phase = .showing(code: started.code)
            startPolling()
        } catch JournalAPIError.notFound {
            guard sessionGeneration == generation else { return }
            phase = .unsupported
        } catch {
            guard sessionGeneration == generation else { return }
            phase = .error("Couldn't reach the server — try again.")
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        let pollGeneration = generation
        pollTask = Task { [weak self] in
            guard let self else { return }
            var interval = self.pollInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, pollGeneration == self.generation else { return }
                if self.isSubmitting { continue } // don't race an in-flight tap
                do {
                    let status = try await self.api.linkStatus()
                    // A stop()/approve()/deny() (each bumps generation) can
                    // have landed a terminal phase while this linkStatus()
                    // was in flight; abandon before any phase write so the
                    // late response can't resurrect e.g. .claimed over
                    // .approved.
                    guard !Task.isCancelled, pollGeneration == self.generation else { return }
                    switch status {
                    case .waiting:
                        break // phase already .showing
                    case .claimed(let deviceName, let requesterIP, _):
                        if case .claimed = self.phase {} else {
                            self.phase = .claimed(deviceName: deviceName, requesterIP: requesterIP)
                        }
                    }
                    interval = self.pollInterval
                } catch JournalAPIError.notFound {
                    // Expired (routine): regenerate silently. startSession
                    // spawns a fresh poll task; this one must end.
                    guard !Task.isCancelled, pollGeneration == self.generation else { return }
                    // An in-flight offer must not have its session replaced
                    // — but the loop has to survive to regenerate once the
                    // offer clears, or the device strands on a dead QR.
                    if self.isSubmitting { continue }
                    await self.startSession()
                    return
                } catch JournalAPIError.unauthenticated {
                    // Starter signed out / revoked mid-flow: the host view
                    // closes on its own sign-out path; stop quietly.
                    return
                } catch {
                    interval = self.errorPollInterval // network loss: back off, keep trying
                }
            }
        }
    }
}
