import Foundation
import MatrixRustSDK

/// Static config for the Matrix-side pusher record. The four `app_id`
/// values must each have a matching app entry in Sygnal's
/// `sygnal.yaml` — see `docs/superpowers/plans/2026-05-02-matron-ios-phase-4-push-nse.md`
/// Task 9 ("Server-side runbook") for the per-platform/per-build
/// `use_sandbox` pairing rules. Mismatch (Debug build hitting a
/// production-only app_id, or vice versa) silently rejects the token
/// at Sygnal with `{"rejected": [<token>]}` — never reaches APNs.
public enum PushConfig {
    /// Per-platform AND per-build-configuration `app_id`. Sygnal routes
    /// each to a distinct APNs endpoint with the right bundle topic +
    /// sandbox flag, so a Debug iOS build never hits the production
    /// APNs gateway and a Release Mac build never hits the sandbox
    /// gateway.
    public static let appID: String = {
        #if os(iOS)
            #if DEBUG
            return "chat.matron.ios.dev"
            #else
            return "chat.matron.ios"
            #endif
        #elseif os(macOS)
            #if DEBUG
            return "chat.matron.mac.dev"
            #else
            return "chat.matron.mac"
            #endif
        #endif
    }()

    /// `app_display_name` reported to Sygnal. Used by the homeserver UI
    /// when surfacing per-pusher records to the user.
    public static let appDisplayName = "Matron"

    /// Push payload format. `.eventIdOnly` is the silent-payload shape
    /// Element X / matrix-rust-sdk standardise on — APNs delivers just
    /// the room+event IDs, the NSE / in-process delegate fetches the
    /// encrypted event from the homeserver and decrypts on-device. No
    /// plaintext leaves the homeserver. Typed against the SDK's
    /// `PushFormat` enum (rather than the wire-level string
    /// `"event_id_only"`) so a future enum case addition fails to
    /// compile here instead of silently leaking content.
    public static let pushFormat: PushFormat = .eventIdOnly

    /// Pusher language for any homeserver-side fallback rendering. We
    /// decrypt + render locally so this is mostly cosmetic; pinning to
    /// `en` keeps Sygnal logs readable.
    public static let language = "en"
}
