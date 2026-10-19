import Foundation
import Observation
import MatronJournal

/// Settings → Security: whether two-factor sign-in is on (`GET /2fa`).
/// Read-only in the apps for now; turning it on or off and making new
/// recovery codes happen in Matron Web.
@Observable @MainActor
public final class TwoFactorSettingsModel {
    public enum Phase: Equatable {
        case loading
        case loaded(TwoFactorStatus)
        /// The journal predates two-factor: the section hides.
        case unsupported
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    /// Set when a refresh failed after a status was shown: the status on
    /// screen may be out of date, and the footer says so.
    public private(set) var isStale = false

    /// The words, in one place so the iPhone and the Mac say the same thing.
    public static let title = "Two-factor sign-in"
    public static let manageNote = "Manage two-factor in Matron Web."
    public static let webLinkTitle = "Open Matron Web"

    private let api: any TwoFactorStatusProviding

    public init(api: any TwoFactorStatusProviding) {
        self.api = api
    }

    /// Whether the settings screens show the section at all.
    public var isShown: Bool { phase != .unsupported }

    /// "On" or "Off", or nil while there is nothing to say.
    public var statusText: String? {
        guard case .loaded(let status) = phase else { return nil }
        return status.enabled ? "On" : "Off"
    }

    /// The line under the switch-shaped status row.
    public var detailText: String? {
        guard case .loaded(let status) = phase else { return nil }
        var lines: [String] = []
        if status.enabled, let left = status.recoveryCodesLeft {
            lines.append(left == 1 ? "1 recovery code left." : "\(left) recovery codes left.")
        }
        if status.required {
            lines.append("This server requires two-factor for everyone.")
        } else if !status.available {
            lines.append("This server can't set up two-factor right now.")
        }
        if isStale {
            lines.append("Couldn't check for changes, so this may be out of date.")
        }
        lines.append(Self.manageNote)
        return lines.joined(separator: " ")
    }

    public func refresh() async {
        do {
            phase = .loaded(try await api.twoFactorStatus())
            isStale = false
        } catch JournalAPIError.notFound {
            phase = .unsupported
        } catch {
            // Keep a status already shown over a transient failure, marked
            // as possibly out of date.
            if case .loaded = phase {
                isStale = true
                return
            }
            phase = .failed(error.localizedDescription)
        }
    }
}
