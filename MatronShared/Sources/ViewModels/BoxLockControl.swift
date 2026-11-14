import Foundation
import MatronJournal

/// Unlocking a locked box for a set time, locking it again, and clearing
/// its lockdown. The journal only carries these requests: the box checks
/// the signature itself, against keys pinned on it.
public enum BoxLockControl {
    /// The unlock lengths the app offers, in minutes. The box's own
    /// setting caps what it accepts.
    public static let offeredMinutes = [15, 30, 60, 120]
    public static let defaultMinutes = 30

    public enum Failure: Error, Equatable, Sendable {
        /// The user backed out of the approval.
        case cancelled
        /// The box is in lockdown: only clearing it gets through.
        case lockdown(String)
        case message(String)

        public var text: String? {
            switch self {
            case .cancelled: return nil
            case .lockdown(let text), .message(let text): return text
            }
        }
    }

    /// Opens an unlock window of `minutes` on `box`, signed by this
    /// device's key. During it the box takes instructions from this device
    /// only.
    public static func unlock(box: DeviceDTO, minutes: Int, api: any AgentRPCProviding,
                              signer: ApprovalSigner?) async -> Failure? {
        await signed(box: box, method: "unlock", api: api, signer: signer, request: ApprovalRequest(
            kind: .account, subject: ApprovalSubjects.unlockBox(box: box.name, minutes: minutes),
            headline: "Unlock \(box.name) for \(durationText(minutes))",
            detail: "While it is unlocked, \(box.name) takes instructions from this device only.",
            box: box.name))
    }

    /// Ends the lockdown a box put itself into after refused approvals.
    public static func clearLockdown(box: DeviceDTO, api: any AgentRPCProviding, signer: ApprovalSigner?) async -> Failure? {
        await signed(box: box, method: "clear_lockdown", api: api, signer: signer, request: ApprovalRequest(
            kind: .account, subject: ApprovalSubjects.clearLockdown(box: box.name),
            headline: "Clear the lockdown on \(box.name)",
            detail: "\(box.name) stopped taking approvals after several were refused. Clear this only if those were yours.",
            box: box.name))
    }

    /// Ends an unlock window early. Needs no signature.
    public static func lock(box: DeviceDTO, api: any AgentRPCProviding) async -> Failure? {
        await send(box: box, method: "lock", params: [:], api: api)
    }

    private static func signed(box: DeviceDTO, method: String, api: any AgentRPCProviding, signer: ApprovalSigner?,
                               request: ApprovalRequest) async -> Failure? {
        let approval: SignedApproval?
        do {
            approval = try await signer?(request)
        } catch ApprovalKeyFailure.cancelled {
            return .cancelled
        } catch {
            return .message(error.localizedDescription)
        }
        // A box checks against its own pinned keys, whatever the account
        // has: with no key to sign with there is nothing to send.
        guard let approval else {
            return .message("This needs an approval key. Set one up in Settings ▸ Approval keys, and have its fingerprint pinned on the box.")
        }
        return await send(box: box, method: method, params: ["approval": approval.json], api: api)
    }

    private static func send(box: DeviceDTO, method: String, params: [String: Any], api: any AgentRPCProviding) async -> Failure? {
        let data = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        do {
            switch try await api.agentRequest(agentDeviceID: box.id, method: method, paramsData: data) {
            case .ok: return nil
            case .failure(let code, let detail): return failure(box: box.name, code: code, detail: detail)
            }
        } catch {
            return .message("\(box.name) didn't answer. \(error.localizedDescription)")
        }
    }

    /// The box's refusal, in words. Its codes are the bridge's own; an
    /// unknown one is shown as it came.
    static func failure(box: String, code: String, detail: String?) -> Failure {
        let reason = detail ?? ""
        switch code {
        case "lockdown", "locked_down":
            return .lockdown("\(box) is in lockdown after refused approvals. Clear the lockdown to use it again.")
        case "approval_invalid":
            if reason == "unknown_key" {
                return .message("\(box) doesn't have this device's approval key pinned. Add the fingerprint to the box's key file.")
            }
            if reason == "lockdown" {
                return .lockdown("\(box) is in lockdown after refused approvals. Clear the lockdown to use it again.")
            }
            return .message(JournalAPIError.approvalInvalidText(reason))
        case "approval_required":
            return .message("\(box) needs a signed approval for this.")
        case "bad_minutes", "minutes_over_cap":
            return .message("\(box) doesn't allow an unlock that long. Pick a shorter time.")
        case "not_locked":
            return .message("\(box) is not in locked mode.")
        case "agent_unreachable":
            return .message("\(box) isn't connected.")
        case "unknown_method", "bad_method", "not_supported":
            return .message("\(box) doesn't support locking yet. Update its bridge.")
        case "account_locked":
            return .message("This account is locked.")
        default:
            return .message(reason.isEmpty ? "\(box) refused (\(code))." : "\(box) refused (\(code): \(reason)).")
        }
    }

    /// "30 minutes", "1 hour", "2 hours".
    public static func durationText(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// "Unlocked for 24 more minutes", "Unlocked for under a minute", or
    /// "Locked".
    public static func stateText(_ lock: BoxLock, now: Date = Date()) -> String {
        guard let until = lock.until, until > now else { return "Locked" }
        let minutes = Int((until.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 1 { return "Unlocked for under a minute" }
        return "Unlocked for \(minutes) more minutes"
    }
}
