import Foundation
import MatronJournal

/// Decides whether this install's APNs tokens belong to Apple's sandbox or
/// production environment.
///
/// The obvious rule — `#if DEBUG` → sandbox, else prod — is wrong, and was
/// wrong in a way that silently killed push on every locally installed
/// Release build. The environment a token belongs to is fixed by the
/// `aps-environment` entitlement in the provisioning profile the app was
/// SIGNED with, not by the configuration it was COMPILED in. A Release build
/// signed with a development profile (`xcodebuild -configuration Release`
/// then `devicectl device install`, which is how the phone gets its builds)
/// carries `aps-environment: development`, so iOS hands it a sandbox token —
/// while `#if DEBUG` is false, so the app announced `prod`. The journal then
/// sent that sandbox token to `api.push.apple.com` and APNs answered
/// `400 BadDeviceToken` every single time.
///
/// So read the entitlement instead. The signed profile is the same artifact
/// APNs itself keys on, which makes this correct for every install path
/// rather than for the two the compile-time rule happened to cover.
public enum PushEnvironmentResolver {
    /// Entitlement keys carrying the APNs environment. iOS uses the bare
    /// name; macOS uses the `com.apple.developer.` prefixed one.
    private static let entitlementKeys = ["aps-environment", "com.apple.developer.aps-environment"]

    /// The embedded profile, by platform. iOS bundles it at the root as
    /// `embedded.mobileprovision`; macOS puts `embedded.provisionprofile`
    /// inside `Contents/`. `Bundle.url(forResource:)` finds both.
    private static let profileResources = [
        ("embedded", "mobileprovision"),
        ("embedded", "provisionprofile"),
    ]

    /// Resolve from `bundle`, falling back to `compiledDefault` when the
    /// bundle carries no profile.
    ///
    /// A missing profile is the normal App Store case: distribution strips
    /// the embedded profile, and those builds are always production — which
    /// is exactly what the compile-time default says for a Release build.
    /// TestFlight builds DO embed a profile (`production`), so they are read
    /// rather than assumed.
    public static func resolve(
        bundle: Bundle = .main,
        compiledDefault: JournalAPI.PushEnvironment = defaultForBuildConfiguration
    ) -> JournalAPI.PushEnvironment {
        resolve(profileData: profileData(in: bundle), compiledDefault: compiledDefault)
    }

    /// The decision itself, over bytes rather than a bundle. `Bundle` is a
    /// class cluster that can't be meaningfully subclassed for a test, so the
    /// lookup and the decision are separate: this half is what the tests
    /// drive, and the bundle overload above is the thin locator.
    public static func resolve(
        profileData: Data?,
        compiledDefault: JournalAPI.PushEnvironment = defaultForBuildConfiguration
    ) -> JournalAPI.PushEnvironment {
        guard let profileData else { return compiledDefault }
        return environment(fromProfile: profileData) ?? compiledDefault
    }

    /// `#if DEBUG` → sandbox, else prod. Only consulted when there is no
    /// profile to read, or when one is present but unreadable.
    public static var defaultForBuildConfiguration: JournalAPI.PushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .prod
        #endif
    }

    private static func profileData(in bundle: Bundle) -> Data? {
        for (name, ext) in profileResources {
            if let url = bundle.url(forResource: name, withExtension: ext),
               let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }

    /// Pull `aps-environment` out of a provisioning profile's bytes.
    ///
    /// The file is a CMS (PKCS#7) signed container wrapping an XML plist.
    /// Rather than decode the signature — the OS already verified it, and we
    /// are reading our own bundle, not deciding trust — locate the embedded
    /// plist by its `<?xml` … `</plist>` bounds and parse that. Returns nil
    /// for anything unparseable so the caller can fall back rather than
    /// registering an environment invented from a damaged file.
    ///
    /// `internal` so the tests can drive it with fixture bytes; nothing
    /// outside this type needs it.
    static func environment(fromProfile data: Data) -> JournalAPI.PushEnvironment? {
        guard let plist = embeddedPlist(in: data),
              let parsed = try? PropertyListSerialization.propertyList(from: plist, format: nil),
              let root = parsed as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any]
        else { return nil }

        for key in entitlementKeys {
            guard let value = entitlements[key] as? String else { continue }
            switch value {
            case "development": return .sandbox
            case "production": return .prod
            default: return nil
            }
        }
        return nil
    }

    /// The plist payload inside the signed container. Searched from the end
    /// for `</plist>` so a `</plist>` appearing inside the certificate blob
    /// (it cannot today, but the search costs nothing) can't truncate it.
    private static func embeddedPlist(in data: Data) -> Data? {
        guard let open = Data("<?xml".utf8).firstRange(in: data),
              let close = Data("</plist>".utf8).lastRange(in: data),
              close.upperBound > open.lowerBound
        else { return nil }
        return data[open.lowerBound..<close.upperBound]
    }
}

private extension Data {
    func firstRange(in haystack: Data) -> Range<Data.Index>? {
        haystack.range(of: self)
    }

    func lastRange(in haystack: Data) -> Range<Data.Index>? {
        haystack.range(of: self, options: .backwards)
    }
}
