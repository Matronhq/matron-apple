import Foundation
import MatronJournal

/// Show-side of the reverse QR flow (spec §2): a signed-out device that
/// can't scan generates a single-use offer key, asks the shared relay for a
/// rendezvous, renders {rid, key} as a v=2 QR, and polls. When a signed-in
/// phone scans it and posts an opaque box (server+code sealed under that
/// key), this VM opens the box locally and hands {server, code} to the
/// existing LinkSignInViewModel — from there the flow is byte-for-byte the
/// shipped claim → approve → token path against the user's own journal. The
/// relay only ever holds ciphertext; it never sees the key, a token, or a
/// readable {server, code} (rendezvous-offer-encryption spec §4.2).
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
    private let keyProvider: @Sendable () -> Data
    // Same stale-async discipline as LinkSignInViewModel/DeviceLinkViewModel:
    // stop() bumps the generation; every post-await branch re-checks it
    // before touching state.
    private var generation = 0
    private var pollTask: Task<Void, Never>?

    public init(relay: any RelayRendezvousing, link: LinkSignInViewModel,
                pollInterval: Duration = .seconds(2), errorPollInterval: Duration = .seconds(5),
                keyProvider: @escaping @Sendable () -> Data = { RendezvousCrypto.generateKey() }) {
        self.relay = relay
        self.link = link
        self.pollInterval = pollInterval
        self.errorPollInterval = errorPollInterval
        self.keyProvider = keyProvider
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
            let key = keyProvider()
            phase = .showing(qrPayload: RendezvousURI.format(rid: rendezvous.rid, key: key))
            startPolling(rid: rendezvous.rid, secret: rendezvous.secret, key: key, gen: gen)
        } catch {
            guard gen == generation else { return }
            phase = .error("Couldn't reach the Matron relay — check your connection and try again.")
        }
    }

    private func startPolling(rid: String, secret: String, key: Data, gen: Int) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, gen == self.generation else { return }
                do {
                    let result = try await self.relay.pollRendezvous(rid: rid, secret: secret)
                    guard !Task.isCancelled, gen == self.generation else { return }
                    switch result {
                    case .waiting:
                        try? await Task.sleep(for: self.pollInterval)
                    case .offered(let box):
                        // A scan/typed claim may already be in flight on the
                        // shared link VM. Hijacking it here would overwrite the
                        // user's entered server/code and pin this VM's
                        // .connecting host line over a wait that belongs to a
                        // different claim (spec §4 transparency). The relay's
                        // poll is a repeatable read — the box survives until the
                        // rendezvous TTL — so defer: keep polling and pick it up
                        // if the link VM comes back to rest.
                        switch self.link.phase {
                        case .claiming, .waitingForApproval, .signedIn:
                            try? await Task.sleep(for: self.pollInterval)
                            continue
                        case .idle, .error:
                            break
                        }
                        // Open the box locally with the key we published in the
                        // QR. An undecryptable/malformed box (someone who knows
                        // only the rid — not the key — occupied the slot with
                        // garbage) is treated exactly like an expired
                        // rendezvous: regenerate and keep showing.
                        guard let (server, code) = Self.openOffer(box, key: key) else {
                            await self.createAndShow(gen)
                            return
                        }
                        self.phase = .connecting(serverHost: URL(string: server)?.host ?? server)
                        self.link.serverURL = server
                        self.link.codeInput = code
                        await self.link.submitManual()
                        guard gen == self.generation else { return }
                        switch self.link.phase {
                        case .claiming, .waitingForApproval, .signedIn:
                            break // the link VM's own phases drive the UI from here
                        case .idle, .error:
                            self.phase = .error("Couldn't connect to that computer's session — try again.")
                        }
                        return
                    }
                } catch RelayError.notFound {
                    guard !Task.isCancelled, gen == self.generation else { return }
                    await self.createAndShow(gen)
                    return
                } catch {
                    guard !Task.isCancelled, gen == self.generation else { return }
                    try? await Task.sleep(for: self.errorPollInterval)
                }
            }
        }
    }

    /// Decrypt and parse a polled offer box. Returns nil on any failure
    /// (auth failure, short input, non-JSON, or missing fields) — the caller
    /// regenerates. `submitManual()` re-validates `server` via
    /// `ServerURLValidator` on the way into the claim, so no separate URL
    /// validation is needed here.
    private static func openOffer(_ box: Data, key: Data) -> (server: String, code: String)? {
        guard let data = try? RendezvousCrypto.open(box, key: key),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = obj["server"] as? String,
              let code = obj["code"] as? String else {
            return nil
        }
        return (server, code)
    }
}
