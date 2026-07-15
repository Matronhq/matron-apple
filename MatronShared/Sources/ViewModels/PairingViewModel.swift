import Foundation
import MatronJournal

/// Drives the "Add agent" pairing modal: code entry → mandatory
/// requester-IP preview → name + approve → wait-for-claim.
///
/// Flow rules (journal PR #19 spec):
/// - Preview fires automatically (debounced) once the input normalizes to a
///   full 8-char code; the approve affordance only exists in `.preview`,
///   so the requester IP is always shown first (anti-phish requirement).
/// - Approval binds the agent's name but does NOT create the device; the
///   claim loop polls the roster and detects the new agent by `device_id`
///   against a pre-approve snapshot — never by name, which isn't unique.
/// - The poll loop is capped at the pair's TTL (`expiresAt`, from the
///   preview's `expires_in`).
@Observable @MainActor
public final class PairingViewModel {
    public enum Phase: Equatable {
        case enterCode
        case preview(requesterIP: String)
        case waitingForClaim
        case success(agentName: String)
    }

    /// Auto-formatted as `XXXX-XXXX` while typing; sloppy input (lowercase,
    /// spaces, missing hyphen) is accepted and normalized on use.
    public var codeInput: String = "" {
        didSet {
            let formatted = PairingCode.display(codeInput)
            if formatted != codeInput {
                codeInput = formatted // re-enters didSet once; equality stops it
                return
            }
            if oldValue != codeInput { codeChanged() }
        }
    }

    /// Convention: the box's short hostname. Not renameable after approval.
    public var agentName: String = "" {
        didSet {
            duplicateNameWarning = existingNames.contains(agentName)
                ? "You already have an agent called \(agentName)"
                : nil
        }
    }

    public private(set) var phase: Phase = .enterCode
    public private(set) var errorMessage: String?
    /// Pair-code TTL deadline (from the preview). The approve button
    /// disables past this; the claim loop stops at it.
    public private(set) var expiresAt: Date?
    /// Duplicate names are legal server-side — warn, don't block.
    public private(set) var duplicateNameWarning: String?

    private let api: any DevicesProviding
    private let existingNames: [String]
    private let now: () -> Date
    private let pollInterval: Duration
    private let previewDebounce: Duration
    private var previewTask: Task<Void, Never>?
    private var claimTask: Task<Void, Never>?

    public init(api: any DevicesProviding, existingNames: [String],
                now: @escaping () -> Date = Date.init,
                pollInterval: Duration = .seconds(2.5),
                previewDebounce: Duration = .milliseconds(300)) {
        self.api = api
        self.existingNames = existingNames
        self.now = now
        self.pollInterval = pollInterval
        self.previewDebounce = previewDebounce
    }

    private func codeChanged() {
        previewTask?.cancel()
        errorMessage = nil
        if case .success = phase { return } // done — edits are a fresh modal's job
        phase = .enterCode
        expiresAt = nil
        let code = PairingCode.normalize(codeInput)
        guard code.count == PairingCode.length else { return }
        previewTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: previewDebounce)
            guard !Task.isCancelled else { return }
            await self.preview(code: code)
        }
    }

    /// Preview responses belong to the code-entry stage; once approval has
    /// gone through, a late response must not pull the flow back out of
    /// waiting/success.
    private var inCodeEntryStage: Bool {
        switch phase {
        case .enterCode, .preview: return true
        case .waitingForClaim, .success: return false
        }
    }

    private func preview(code: String) async {
        do {
            let preview = try await api.pairPreview(code: code)
            guard !Task.isCancelled, inCodeEntryStage else { return }
            phase = .preview(requesterIP: preview.requesterIP)
            expiresAt = now().addingTimeInterval(TimeInterval(preview.expiresIn))
        } catch JournalAPIError.notFound {
            guard !Task.isCancelled, inCodeEntryStage else { return }
            errorMessage = "Code not recognized or expired. Get a fresh code from the box and try again."
        } catch {
            guard !Task.isCancelled, inCodeEntryStage else { return }
            errorMessage = "Couldn't check that code — try again."
        }
    }

    /// Snapshot the roster, approve the code under `agentName`, then poll
    /// for the box's claim. Returns once the claim loop is RUNNING (it
    /// finishes in the background so the sheet stays dismissible).
    public func approve() async {
        guard case .preview = phase else { return }
        errorMessage = nil
        let code = PairingCode.normalize(codeInput)
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Name the agent first — the name can't be changed later."
            return
        }
        // device_id snapshot BEFORE approving: the claim is detected by a
        // new agent id, never by name (names aren't unique — a pre-existing
        // device with the same name would false-succeed instantly).
        let snapshot: Set<Int64>
        do {
            snapshot = Set(try await api.devices().map(\.id))
        } catch {
            errorMessage = "Couldn't reach the server — try again."
            return
        }
        do {
            try await api.pairApprove(code: code, agentName: name)
        } catch JournalAPIError.conflict {
            errorMessage = "This code was already approved."
            return
        } catch JournalAPIError.notFound {
            errorMessage = "Code not recognized or expired. Get a fresh code from the box and try again."
            return
        } catch {
            errorMessage = "Couldn't approve — try again."
            return
        }
        // A code edit made while the approve round-trip was in flight queues
        // a fresh debounced preview; kill it before entering the wait state.
        previewTask?.cancel()
        previewTask = nil
        phase = .waitingForClaim
        let deadline = expiresAt ?? now().addingTimeInterval(600)
        claimTask = Task { [weak self] in
            await self?.pollForClaim(snapshot: snapshot, deadline: deadline)
        }
    }

    private func pollForClaim(snapshot: Set<Int64>, deadline: Date) async {
        while !Task.isCancelled && now() <= deadline {
            if let claimed = (try? await api.devices())?
                .first(where: { $0.kind == "agent" && !snapshot.contains($0.id) }) {
                guard !Task.isCancelled else { return }
                phase = .success(agentName: claimed.name)
                return
            }
            try? await Task.sleep(for: pollInterval)
        }
        guard !Task.isCancelled else { return }
        errorMessage = "The box never collected its token. Start again with a fresh code."
        phase = .enterCode
    }

    /// Stops the claim poll (the wait is dismissible — the roster shows the
    /// agent whenever it lands regardless).
    public func cancelWaiting() {
        claimTask?.cancel()
        claimTask = nil
    }
}
