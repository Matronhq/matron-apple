import Foundation
import MatronJournal

/// Show-side of the reverse QR flow (spec §2): a signed-out device that
/// can't scan asks the shared relay for a rendezvous, renders it as a QR,
/// and polls. When a signed-in phone scans it and posts {server, code},
/// this VM hands both values to the existing LinkSignInViewModel — from
/// there the flow is byte-for-byte the shipped claim → approve → token
/// path against the user's own journal. The relay never sees a token.
@Observable @MainActor
public final class RendezvousSignInViewModel {
    public enum Phase: Equatable {
        case idle
        case loading
        case showing(qrPayload: String)
        /// Shown before and during the claim so the user can see WHICH
        /// server the relay pointed us at (spec §4: compromised-relay
        /// transparency). The link VM's own phases drive the rest.
        case connecting(serverHost: String)
        case error(String)
    }

    public private(set) var phase: Phase = .idle

    private let relay: any RelayRendezvousing
    private let link: LinkSignInViewModel
    private let pollInterval: Duration
    private let errorPollInterval: Duration
    // Same stale-async discipline as LinkSignInViewModel/DeviceLinkViewModel:
    // stop() bumps the generation; every post-await branch re-checks it
    // before touching state.
    private var generation = 0
    private var pollTask: Task<Void, Never>?

    public init(relay: any RelayRendezvousing, link: LinkSignInViewModel,
                pollInterval: Duration = .seconds(2), errorPollInterval: Duration = .seconds(5)) {
        self.relay = relay
        self.link = link
        self.pollInterval = pollInterval
        self.errorPollInterval = errorPollInterval
    }

    public func start() async {
        generation += 1
        let gen = generation
        pollTask?.cancel()
        pollTask = nil
        phase = .loading
        await createAndShow(gen)
    }

    public func stop() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        phase = .idle
    }

    private func createAndShow(_ gen: Int) async {
        do {
            let rendezvous = try await relay.createRendezvous()
            guard gen == generation else { return }
            phase = .showing(qrPayload: RendezvousURI.format(rid: rendezvous.rid))
            startPolling(rid: rendezvous.rid, secret: rendezvous.secret, gen: gen)
        } catch {
            guard gen == generation else { return }
            phase = .error("Couldn't reach the Matron relay — check your connection and try again.")
        }
    }

    private func startPolling(rid: String, secret: String, gen: Int) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, gen == self.generation else { return }
                do {
                    let result = try await self.relay.pollRendezvous(rid: rid, secret: secret)
                    guard !Task.isCancelled, gen == self.generation else { return }
                    switch result {
                    case .waiting:
                        try? await Task.sleep(for: self.pollInterval)
                    case .offered(let server, let code):
                        self.phase = .connecting(serverHost: URL(string: server)?.host ?? server)
                        self.link.serverURL = server
                        self.link.codeInput = code
                        await self.link.submitManual()
                        return
                    }
                } catch RelayError.notFound {
                    guard !Task.isCancelled, gen == self.generation else { return }
                    // Rendezvous expired: silently regenerate — the mirror of
                    // the show-side's link-expiry regeneration.
                    await self.createAndShow(gen)
                    return
                } catch {
                    guard !Task.isCancelled, gen == self.generation else { return }
                    try? await Task.sleep(for: self.errorPollInterval)
                }
            }
        }
    }
}
