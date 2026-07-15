import Foundation
import MatronJournal

/// The devices/pairing slice of `JournalAPI`, extracted so view models can
/// be tested against a fake without a URL session. `JournalAPI` conforms
/// as-is.
public protocol DevicesProviding: Sendable {
    func devices() async throws -> [DeviceDTO]
    func revokeDevice(id: Int64) async throws
    func pairPreview(code: String) async throws -> PairPreview
    func pairApprove(code: String, agentName: String) async throws
}

extension JournalAPI: DevicesProviding {}

/// Devices-screen state: the signed-in user's device roster with
/// per-device revoke. Pull-based per the server spec — callers `refresh()`
/// on screen enter and the model re-fetches after every mutation; there is
/// no push signal for roster changes in v1.
@Observable @MainActor
public final class DevicesViewModel {
    /// Sorted for display: clients first, then agents, each newest-first.
    public private(set) var devices: [DeviceDTO] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let api: any DevicesProviding
    /// Fired after a successful self-revocation (server treats it as a
    /// logout — the token is already dead). The host app drops local
    /// credentials and returns to sign-in.
    private let onSelfRevoked: () -> Void

    public init(api: any DevicesProviding, onSelfRevoked: @escaping () -> Void) {
        self.api = api
        self.onSelfRevoked = onSelfRevoked
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            devices = Self.sorted(try await api.devices())
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load devices — \(Self.describe(error))"
        }
    }

    /// Revokes `device`. 404 means it was already revoked elsewhere —
    /// treated as success. Self-revocation fires `onSelfRevoked` instead of
    /// re-fetching (the roster call would just 401 on the dead token).
    public func revoke(_ device: DeviceDTO) async {
        do {
            do {
                try await api.revokeDevice(id: device.id)
            } catch JournalAPIError.notFound {
                // Already gone — fall through to the success path.
            }
            if device.isSelf {
                onSelfRevoked()
            } else {
                await refresh()
            }
        } catch {
            errorMessage = "Couldn't revoke \(device.name) — \(Self.describe(error))"
        }
    }

    static func sorted(_ devices: [DeviceDTO]) -> [DeviceDTO] {
        devices.sorted { a, b in
            let aClient = a.kind == "client", bClient = b.kind == "client"
            if aClient != bClient { return aClient }
            return a.createdAt > b.createdAt
        }
    }

    static func describe(_ error: Error) -> String {
        if case JournalAPIError.transport = error { return "check your connection and try again." }
        return "the server said no (\(error))."
    }
}

/// Display helpers shared by the Mac and iOS device rows.
extension DeviceDTO {
    public var isClient: Bool { kind == "client" }

    /// SF Symbol for the row icon: apps are laptops, agents are terminals.
    public var symbolName: String { isClient ? "laptopcomputer" : "terminal" }

    /// `lag` is the user's head seq minus this device's cursor.
    public var lagText: String {
        lag <= 0 ? "Up to date" : "\(lag) event\(lag == 1 ? "" : "s") behind"
    }

    /// Relative last-seen. `nil` = never connected (e.g. an agent enrolled
    /// but whose box hasn't come online) → "Never", per the spec.
    public func lastSeenText(now: Date = Date()) -> String {
        guard let lastSeenAt else { return "Never" }
        let date = Date(timeIntervalSince1970: TimeInterval(lastSeenAt) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
