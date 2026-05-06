import Foundation

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

    /// Push payload format. `event_id_only` is the silent-payload shape
    /// Element X / matrix-rust-sdk standardise on — APNs delivers just
    /// the room+event IDs, the NSE / in-process delegate fetches the
    /// encrypted event from the homeserver and decrypts on-device. No
    /// plaintext leaves the homeserver.
    public static let pushFormat = "event_id_only"

    /// Pusher language for any homeserver-side fallback rendering. We
    /// decrypt + render locally so this is mostly cosmetic; pinning to
    /// `en` keeps Sygnal logs readable.
    public static let language = "en"
}
