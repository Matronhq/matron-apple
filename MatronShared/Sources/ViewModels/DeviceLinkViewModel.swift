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
    /// True while an approve/deny round-trip is in flight; reentrant taps
    /// are ignored and the poll loop skips regeneration to avoid racing
    /// the in-flight request.
    public private(set) var isSubmitting = false

    /// The full QR payload for the current code (nil unless `.showing`).
    public var qrPayload: String? {
        guard case .showing(let code) = phase else { return nil }
        return LinkURI.format(server: serverURL, code: code)
    }

    private let api: any DeviceLinking
    private let serverURL: URL
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
                pollInterval: Duration = .seconds(2),
                errorPollInterval: Duration = .seconds(5)) {
        self.api = api
        self.serverURL = serverURL
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
        pollTask = Task { [weak self] in
            guard let self else { return }
            var interval = self.pollInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                if self.isSubmitting { continue } // don't race an in-flight tap
                do {
                    switch try await self.api.linkStatus() {
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
                    guard !Task.isCancelled, !self.isSubmitting else { return }
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
