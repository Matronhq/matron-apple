import XCTest
import MatronJournal
@testable import MatronPush

/// The bug these pin: a Release build signed with a DEVELOPMENT profile gets
/// a sandbox token from iOS while `#if DEBUG` says `.prod`, so every push to
/// it came back `400 BadDeviceToken`. The entitlement is the authority.
final class PushEnvironmentResolverTests: XCTestCase {
    /// Wraps an entitlements plist the way a real profile does: an XML plist
    /// buried in CMS bytes, with binary noise on both sides.
    private func profileBytes(entitlements: [String: String]) -> Data {
        let entries = entitlements.map { "\t\t<key>\($0.key)</key>\n\t\t<string>\($0.value)</string>" }
            .joined(separator: "\n")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Name</key>
        \t<string>Matron Development</string>
        \t<key>Entitlements</key>
        \t<dict>
        \(entries)
        \t</dict>
        </dict>
        </plist>
        """
        var data = Data([0x30, 0x82, 0x0A, 0x01])  // DER SEQUENCE header, as CMS begins
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0x01, 0x02, 0xFF]))  // trailing signature bytes
        return data
    }

    func testDevelopmentEntitlementMeansSandbox() {
        let data = profileBytes(entitlements: ["aps-environment": "development"])
        XCTAssertEqual(PushEnvironmentResolver.environment(fromProfile: data), .sandbox)
    }

    func testProductionEntitlementMeansProd() {
        let data = profileBytes(entitlements: ["aps-environment": "production"])
        XCTAssertEqual(PushEnvironmentResolver.environment(fromProfile: data), .prod)
    }

    /// macOS profiles spell the key with the `com.apple.developer.` prefix.
    func testMacPrefixedEntitlementKeyIsRead() {
        let data = profileBytes(entitlements: ["com.apple.developer.aps-environment": "development"])
        XCTAssertEqual(PushEnvironmentResolver.environment(fromProfile: data), .sandbox)
    }

    /// The case that was silently broken: compiled Release (so the
    /// compile-time default says prod), signed for development. The profile
    /// wins, and the app registers the sandbox token it actually holds.
    func testProfileOverridesTheCompileTimeDefault() {
        let data = profileBytes(entitlements: ["aps-environment": "development"])
        XCTAssertEqual(PushEnvironmentResolver.resolve(profileData: data, compiledDefault: .prod), .sandbox)
    }

    /// App Store distribution strips the embedded profile. Nothing to read,
    /// so the compile-time default stands — and for those builds it is right.
    func testNoProfileFallsBackToCompiledDefault() {
        XCTAssertEqual(PushEnvironmentResolver.resolve(profileData: nil, compiledDefault: .prod), .prod)
        XCTAssertEqual(PushEnvironmentResolver.resolve(profileData: nil, compiledDefault: .sandbox), .sandbox)
    }

    /// A profile that is present but unreadable must not flip the answer:
    /// the compile-time default stands, same as having no profile at all.
    func testDamagedProfileFallsBackRatherThanGuessing() {
        let garbage = Data([0x30, 0x82, 0xFF, 0x00])
        XCTAssertEqual(PushEnvironmentResolver.resolve(profileData: garbage, compiledDefault: .prod), .prod)
    }

    /// A damaged or truncated profile must not be guessed at — fall back
    /// rather than register an environment invented from garbage.
    func testUnparseableProfileFallsBack() {
        XCTAssertNil(PushEnvironmentResolver.environment(fromProfile: Data([0x30, 0x82, 0xFF])))
        let noPlist = Data("no plist in here at all".utf8)
        XCTAssertNil(PushEnvironmentResolver.environment(fromProfile: noPlist))
    }

    /// An entitlement value Apple hasn't defined is not silently mapped to
    /// either environment.
    func testUnknownEntitlementValueIsRejected() {
        let data = profileBytes(entitlements: ["aps-environment": "staging"])
        XCTAssertNil(PushEnvironmentResolver.environment(fromProfile: data))
    }
}
