import Foundation

/// `GET` / `PUT /notify` (journal spec 2026-10-01 notification settings):
/// what may push, synced per user, plus this device's own level. A protocol
/// so `NotifySettingsStore` tests fake it.
public protocol NotifySettingsProviding: Sendable {
    func notifySettings() async throws -> NotifyView
    /// Returns the whole view as the journal stored it. Throws `.notFound`
    /// for a conversation the user does not own.
    func updateNotify(_ change: NotifyChange) async throws -> NotifyView
}

extension JournalAPI: NotifySettingsProviding {
    public func notifySettings() async throws -> NotifyView {
        try Self.decodeNotifyView(try await request(path: "/notify"))
    }

    public func updateNotify(_ change: NotifyChange) async throws -> NotifyView {
        try Self.decodeNotifyView(try await request(path: "/notify", method: "PUT", body: change.body))
    }

    static func decodeNotifyView(_ obj: [String: Any]) throws -> NotifyView {
        guard let view = NotifyView.decode(obj) else { throw JournalAPIError.transport("malformed /notify response") }
        return view
    }
}
