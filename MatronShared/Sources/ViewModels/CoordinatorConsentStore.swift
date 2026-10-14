import Foundation
import os
import MatronJournal

/// Settings' "Let the Coordinator approve chats and spawns" switch: the
/// journal's `consent` flag on `/coordinator`. Read on `load()`, written
/// optimistically: the toggle moves at once, and a failed `PUT` puts it
/// back and says why.
@Observable @MainActor
public final class CoordinatorConsentStore {
    private static let logger = Logger(subsystem: "chat.matron", category: "coordinator-consent")

    /// `nil` until the journal answers, and for a journal without the
    /// switch — the row hides rather than offering a toggle that does
    /// nothing.
    public private(set) var isEnabled: Bool?
    /// The last failed write, for the row to show. Cleared by the next one.
    public private(set) var errorMessage: String?

    private let api: any CoordinatorConsentProviding
    /// Bumped by every write, so a `GET` that started before one is dropped
    /// rather than undoing the user's tap, and only the latest write's
    /// answer moves the toggle.
    private var epoch = 0
    /// The journal's last known value: where a failed write puts the
    /// toggle back to.
    private var confirmed: Bool?
    /// Writes go one at a time, in tap order, so the journal ends on the
    /// user's last tap — two `PUT`s in flight could land the other way round.
    private var lastWrite: Task<Void, Never>?

    public init(api: any CoordinatorConsentProviding) {
        self.api = api
    }

    public func load() async {
        let startEpoch = epoch
        do {
            let value = try await api.coordinatorConsent()
            guard epoch == startEpoch else { return }
            confirmed = value
            isEnabled = value
        } catch {
            Self.logger.warning("GET /coordinator failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func set(_ enabled: Bool) async {
        guard isEnabled != enabled else { return }
        epoch += 1
        let writeEpoch = epoch
        isEnabled = enabled
        errorMessage = nil
        let prior = lastWrite
        let write = Task { @MainActor [api] in
            await prior?.value
            do {
                let stored = try await api.setCoordinatorConsent(enabled) ?? enabled
                self.confirmed = stored
                if self.epoch == writeEpoch { self.isEnabled = stored }
            } catch {
                guard self.epoch == writeEpoch else { return }
                self.isEnabled = self.confirmed
                self.errorMessage = error.localizedDescription
            }
        }
        lastWrite = write
        await write.value
    }
}
