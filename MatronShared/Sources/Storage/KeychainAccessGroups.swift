import Foundation

/// Centralised access-group constants for every `KeychainStore` we
/// construct in production (Phase 3 / Wave 3 / B3 fix-up).
///
/// Today the apps only declare one group per platform in the entitlements
/// plist, so omitting `kSecAttrAccessGroup` from `SecItemAdd`/`SecItemCopyMatching`
/// lets the system fall back to "the first entry in `keychain-access-groups`"
/// — which happens to be ours, so reads + writes work. Phase 4 adds a second
/// access group on iOS (for sharing the recovery / push-decryption material
/// with `MatronNSE`); the implicit-default behaviour means items written
/// today land in whichever group the system happens to pick first, and a
/// future explicit `accessGroup:` argument won't see them. By pinning the
/// group at every construction site, the items live in a known group from
/// day one and Phase 4 can layer on a second store without invalidating the
/// existing recovery keys.
///
/// The `$(AppIdentifierPrefix)` token is expanded by the system at runtime
/// from the bundle's signed entitlements blob. Tests can compare against
/// the suffix only (`hasSuffix("chat.matron")` etc.) since the team prefix
/// is signing-identity-dependent and not stable across machines.
public enum KeychainAccessGroups {
    /// Recovery-key Keychain access group. Mirrors the
    /// `keychain-access-groups` entry in the platform entitlements file:
    /// - iOS: `Matron/App/Matron.entitlements`
    /// - macOS: `MatronMac/App/MatronMac.entitlements`
    ///
    /// The string is platform-specific because the bundles ship with
    /// different `PRODUCT_BUNDLE_IDENTIFIER`s (`chat.matron.app` on iOS,
    /// `chat.matron.mac` on macOS) and the access group is derived from
    /// (a subset of) that identifier. The Phase-3-stable iOS suffix is
    /// `chat.matron` (NOT `chat.matron.app`) so Phase 4 can add a second
    /// group keyed on the app group — `$(AppIdentifierPrefix)chat.matron`
    /// is the existing matrix-shared prefix that both the app and the NSE
    /// can be granted without churning the existing entry.
    public static let recovery: String = {
        #if os(macOS)
        return "$(AppIdentifierPrefix)chat.matron.mac"
        #else
        return "$(AppIdentifierPrefix)chat.matron"
        #endif
    }()
}
