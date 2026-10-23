import Foundation
import Observation
import MatronJournal

/// Settings → Security: whether two-factor sign-in is on (`GET /2fa`), and
/// which of Set Up…, New Recovery Codes…, Change App… and Turn Off… apply.
/// The words follow Matron Web's Settings → Security.
@Observable @MainActor
public final class TwoFactorSettingsModel {
    public enum Phase: Equatable {
        case loading
        case loaded(TwoFactorStatus)
        /// The journal predates two-factor: the section hides.
        case unsupported
        case failed(String)
    }

    /// The sheet a button opens.
    public enum Action: String, Identifiable, Sendable {
        case setUp, newRecoveryCodes, changeApp, turnOff
        public var id: String { rawValue }
    }

    public private(set) var phase: Phase = .loading
    /// Set when a refresh failed after a status was shown: the status on
    /// screen may be out of date, and the footer says so.
    public private(set) var isStale = false

    /// The words, in one place so the iPhone and the Mac say the same thing.
    public static let title = "Two-factor sign-in"
    public static let setUpTitle = "Set Up…"
    public static let newRecoveryCodesTitle = "New Recovery Codes…"
    public static let changeAppTitle = "Change App…"
    public static let turnOffTitle = "Turn Off…"
    public static let lowRecoveryCodesWarning = "You're running out of recovery codes. Make a new set."
    /// Fewer recovery codes than this left, and the section suggests a new set.
    public static let lowRecoveryCodes = 3

    public let api: any TwoFactorSettingsProviding
    private let locale: Locale
    private let timeZone: TimeZone

    public init(api: any TwoFactorSettingsProviding, locale: Locale = .current, timeZone: TimeZone = .current) {
        self.api = api
        self.locale = locale
        self.timeZone = timeZone
    }

    /// Whether the settings screens show the section at all.
    public var isShown: Bool { phase != .unsupported }

    public var status: TwoFactorStatus? {
        guard case .loaded(let status) = phase else { return nil }
        return status
    }

    /// "On" or "Off", or nil while there is nothing to say.
    public var statusText: String? {
        status.map { $0.enabled ? "On" : "Off" }
    }

    /// The line under the status row: "On since 3 Oct 2026 · 7 recovery
    /// codes left", or what "off" means here.
    public var detailText: String? {
        guard let status else { return nil }
        if status.enabled {
            var parts: [String] = []
            if let since = enabledSince(status) { parts.append("On since \(since)") }
            if let left = status.recoveryCodesLeft {
                parts.append(left == 1 ? "1 recovery code left" : "\(left) recovery codes left")
            }
            return parts.isEmpty ? "On." : parts.joined(separator: " · ")
        }
        return status.available
            ? "Off. Signing in takes only your password."
            : "This server isn't set up for two-factor sign-in."
    }

    /// Lines for the section's footer: the low-codes warning, the server's
    /// requirement, a stale status.
    public var footerText: String? {
        var lines: [String] = []
        if case .failed(let message) = phase { lines.append(message) }
        if status?.required == true { lines.append("This server requires two-factor sign-in for everyone.") }
        if isStale { lines.append("Couldn't check for changes, so this may be out of date.") }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// Shown in red above the buttons when the user is down to their last
    /// few recovery codes.
    public var showsLowRecoveryCodesWarning: Bool {
        guard let status, status.enabled, let left = status.recoveryCodesLeft else { return false }
        return left < Self.lowRecoveryCodes
    }

    /// The buttons, in order. Turn Off… is hidden while the server requires
    /// two-factor; Set Up… while the server can't store secrets.
    public var actions: [Action] {
        guard let status else { return [] }
        if status.enabled {
            return status.required ? [.newRecoveryCodes, .changeApp] : [.newRecoveryCodes, .changeApp, .turnOff]
        }
        return status.available ? [.setUp] : []
    }

    public static func title(for action: Action) -> String {
        switch action {
        case .setUp: return setUpTitle
        case .newRecoveryCodes: return newRecoveryCodesTitle
        case .changeApp: return changeAppTitle
        case .turnOff: return turnOffTitle
        }
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
            phase = .failed("Couldn't load two-factor settings: \(error.localizedDescription)")
        }
    }

    private func enabledSince(_ status: TwoFactorStatus) -> String? {
        guard let ms = status.enabledAt else { return nil }
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone).day().month(.abbreviated).year()
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000).formatted(style)
    }
}
