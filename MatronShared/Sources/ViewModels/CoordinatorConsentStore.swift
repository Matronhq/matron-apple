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
    /// rather than undoing the user's tap.
    private var epoch = 0

    public init(api: any CoordinatorConsentProviding) {
        self.api = api
    }

    public func load() async {
        let startEpoch = epoch
        do {
            let value = try await api.coordinatorConsent()
            guard epoch == startEpoch else { return }
            isEnabled = value
        } catch {
            Self.logger.warning("GET /coordinator failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func set(_ enabled: Bool) async {
        guard isEnabled != enabled else { return }
        let previous = isEnabled
        epoch += 1
        let writeEpoch = epoch
        isEnabled = enabled
        errorMessage = nil
        do {
            let stored = try await api.setCoordinatorConsent(enabled)
            guard epoch == writeEpoch else { return }
            isEnabled = stored ?? enabled
        } catch {
            guard epoch == writeEpoch else { return }
            isEnabled = previous
            errorMessage = error.localizedDescription
        }
    }
}
