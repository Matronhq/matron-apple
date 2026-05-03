import Foundation

/// Centralised naming for the recovery-key Keychain entry (Phase 3 / Wave 5).
///
/// **Wave 5 bugbot #3 revert.** Earlier waves named full access-group strings
/// here — `$(AppIdentifierPrefix)chat.matron[.mac]` — and passed them to
/// `kSecAttrAccessGroup`. That was wrong: `$(AppIdentifierPrefix)` is an
/// Xcode build-time variable that's only expanded inside entitlement plists
/// during signing. Swift string literals containing the token are passed
/// through to `SecItemAdd` / `SecItemCopyMatching` unmodified, so every
/// signed build (TestFlight, App Store, signed dev with entitlements)
/// returned `errSecMissingEntitlement (-34018)` and silently failed
/// recovery-key persistence — exactly the failure mode `KeychainProbe` was
/// added to catch.
///
/// Today the apps each declare exactly one entry in `keychain-access-groups`,
/// so `KeychainStore` can omit `kSecAttrAccessGroup` entirely and the system
/// falls back to "the first entry in `keychain-access-groups`" — which is
/// ours. That's how the recovery-key flow shipped pre-Wave-3 and how it
/// works today. The constants below name the SUFFIX of each platform's
/// access-group entitlement so tests can lock the entitlement-file shape
/// (the `$(AppIdentifierPrefix)` half is signing-team-dependent and not
/// stable across machines).
///
/// **Phase 4 — when iOS NSE adds a second `keychain-access-groups` entry,**
/// the implicit-default-of-first-entry behaviour STILL works as long as the
/// recovery group remains the first entry. If the order needs to change, or
/// reads need to reach across both groups, the correct mechanism is a
/// runtime probe: `SecItemCopyMatching` with `kSecReturnAttributes: true`,
/// read the resolved `kSecAttrAccessGroup` from the result, cache it. That's
/// more code than the issue is worth right now (it would also need to make
/// the previously-sync `KeychainStore` factory async/throws), so today we
/// stay on implicit-default + an explicit TODO so a Phase 4 reviewer
/// catches the assumption.
public enum KeychainAccessGroups {
    /// The suffix of the recovery-key Keychain access group — what the
    /// `keychain-access-groups` entry in each platform's entitlements file
    /// reads after the team-dependent `$(AppIdentifierPrefix)` prefix.
    /// Tests assert against this; production code does NOT pass this string
    /// to `kSecAttrAccessGroup` (see file docblock for the historical bug).
    ///
    /// Mirrors the `keychain-access-groups` entry in:
    /// - iOS: `Matron/App/Matron.entitlements`
    /// - macOS: `MatronMac/App/MatronMac.entitlements`
    public static let recoverySuffix: String = {
        #if os(macOS)
        return "chat.matron.mac"
        #else
        return "chat.matron"
        #endif
    }()
}
