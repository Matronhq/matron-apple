import UserNotifications
import MatrixRustSDK
import MatronAuth
import MatronPush
import MatronStorage
import MatronSync

/// iOS Notification Service Extension entry point. APNs delivers a
/// silent payload (`room_id` + `event_id`) to this `.appex` process;
/// `didReceive` bootstraps a Client off the App-Group-shared SDK store,
/// fetches + decrypts the event via `PushDecoder`, and rewrites the
/// system notification with the decoded title + body before handing
/// it back to iOS for display.
///
/// The 30-second `serviceExtensionTimeWillExpire` budget is the iOS
/// limit; if the SDK can't fetch+decrypt in that window we fall back
/// to a generic body so the user sees SOMETHING — better than the
/// raw encrypted placeholder APNs would otherwise show.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent

        // The Sygnal `event_id_only` payload puts the IDs into
        // `userInfo`. If they're missing we can't fetch the event —
        // fall through to whatever body APNs already supplied (which
        // is just the encrypted placeholder, but at least notifies
        // the user that something happened).
        guard let userInfo = request.content.userInfo as? [String: Any],
              let roomID = userInfo["room_id"] as? String,
              let eventID = userInfo["event_id"] as? String else {
            contentHandler(request.content)
            return
        }

        Task {
            do {
                let decoded = try await Self.decode(roomID: roomID, eventID: eventID)
                deliver(decoded: decoded, roomID: roomID, eventID: eventID)
            } catch {
                fallback()
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // iOS is about to terminate the extension; deliver whatever
        // we've got rather than nothing. Touches the same `bestAttempt`
        // the in-flight Task may also be writing — UNUserNotificationCenter
        // documents that the contentHandler is safe to call multiple
        // times (only the first call delivers), so the worst case is
        // a redundant call, not a crash.
        fallback()
    }

    /// Stands up just enough of the host app's storage layout to open
    /// a Client, restore the persisted session, and decode the event.
    /// Mirrors `AppDependencies` (Matron/App/AppDependencies.swift) —
    /// the App-Group-shared `sdk-store/` for the SDK SQLite + crypto,
    /// and `sessions/` for the FileSessionStore session JSON. Today
    /// the host writes via `FileSessionStore`, so the NSE reads via
    /// `FileSessionStore` to match. Switching the host to KeychainStore
    /// (with the shared `keychain-access-groups` entitlement that
    /// landed in Task 1 Step 0) is a follow-up — both processes need
    /// to swap together.
    ///
    /// SDK tracing setup runs FIRST. `initPlatform(...)` is process-
    /// local: the NSE is a separate process from the iOS host, so the
    /// host's `MatronApp.bootstrap()` setup never reaches us. Without
    /// this call the SDK runs silent in the extension — every internal
    /// notification-fetch / decrypt / `/sync` round-trip would fail
    /// without a diagnostic anywhere in the unified log, exactly the
    /// gap that stranded the matron-vs-matron-ui scenario for a full
    /// session of debugging in Phase 3 (cursor PR #5 second-pass
    /// finding "NSE skips SDK platform setup"). `useLightweightTokioRuntime: true`
    /// per the iOS NSE 30s / 24MB memory budget — the doc-comment on
    /// `MatronSDKTracing.setup` flags this as the extension shape.
    private static func decode(roomID: String, eventID: String) async throws -> DecodedNotification {
        await MatronSDKTracing.setup(useLightweightTokioRuntime: true)
        guard let container = StoragePaths.groupContainer else {
            throw NSEBootstrapError.missingAppGroupContainer
        }
        let sdkStore = container.appendingPathComponent("sdk-store")
        let sessionsDir = container.appendingPathComponent("sessions")
        let sessionStore = FileSessionStore(directory: sessionsDir)
        let auth = AuthServiceLive(sessionStore: sessionStore, basePath: sdkStore)
        guard let session = try await auth.restoreSession() else {
            throw NSEBootstrapError.noPersistedSession
        }
        let provider = ClientProvider(basePath: sdkStore)
        // NSE runs in a separate process from the iOS host, so the
        // notification client coordinates with the host via
        // `.multipleProcesses`. Mac uses `.singleProcess(syncService:)`
        // — see PushDecoder.live's doc-comment for the full split.
        let decoder = PushDecoder.live(
            provider: provider,
            session: session,
            processSetup: .multipleProcesses
        )
        return try await decoder.decode(roomID: roomID, eventID: eventID)
    }

    private func deliver(decoded: DecodedNotification, roomID: String, eventID: String) {
        guard let content = bestAttempt, let handler = contentHandler else { return }
        content.title = decoded.title
        content.body = decoded.body
        content.threadIdentifier = decoded.threadIdentifier ?? roomID
        if let badge = decoded.badge {
            content.badge = NSNumber(value: badge)
        }
        // Preserve the IDs so the host app's `NotificationDelegate`
        // (Task 6) can deep-link to the right room when the user
        // taps the notification.
        content.userInfo["room_id"] = roomID
        content.userInfo["event_id"] = eventID
        handler(content)
    }

    private func fallback() {
        guard let handler = contentHandler else { return }
        if let content = bestAttempt {
            content.title = "Matron"
            content.body = "New message"
            handler(content)
        } else {
            handler(UNNotificationContent())
        }
    }
}

private enum NSEBootstrapError: Error {
    /// The App-Group entitlement isn't provisioned (build without
    /// signing, or a stripped entitlement). The .appex literally has
    /// no shared container to read.
    case missingAppGroupContainer
    /// `FileSessionStore` returned no persisted UserSession — the user
    /// signed out, or the host app has never been launched.
    case noPersistedSession
}
