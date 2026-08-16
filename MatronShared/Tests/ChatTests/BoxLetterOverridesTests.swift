import XCTest
@testable import MatronChat

final class BoxLetterOverridesTests: XCTestCase {

    /// A scratch suite per test run — never `.standard`, which is the real
    /// app domain on this machine (probe-name pollution gotcha).
    private var defaults: UserDefaults!
    private let suiteName = "BoxLetterOverridesTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSetReadClearRoundTrip() {
        BoxLetterOverrides.set("q", for: 7, in: defaults)
        XCTAssertEqual(BoxLetterOverrides.letter(for: 7, from: defaults), "q")
        XCTAssertEqual(BoxLetterOverrides.all(from: defaults), [7: "q"])

        // Blank means "back to automatic": the override is removed, and the
        // last removal drops the whole defaults key.
        BoxLetterOverrides.set("  ", for: 7, in: defaults)
        XCTAssertNil(BoxLetterOverrides.letter(for: 7, from: defaults))
        XCTAssertNil(defaults.object(forKey: BoxLetterOverrides.defaultsKey))
    }

    func testSanitizeKeepsOneGraphemeAsTyped() {
        // The character is the user's pick — case preserved, emoji fine,
        // but only the FIRST grapheme survives.
        XCTAssertEqual(BoxLetterOverrides.sanitize(" mz "), "m")
        XCTAssertEqual(BoxLetterOverrides.sanitize("🦊box"), "🦊")
        XCTAssertNil(BoxLetterOverrides.sanitize("   "))
        XCTAssertNil(BoxLetterOverrides.sanitize(""))
    }

    func testSetPostsTheChangeNotification() {
        let posted = expectation(forNotification: BoxLetterOverrides.didChange, object: nil)
        BoxLetterOverrides.set("x", for: 1, in: defaults)
        wait(for: [posted], timeout: 1)
    }

    func testOverrideReplacesTheDerivedLetterWithoutShiftingOthers() {
        let names: [Int64: String] = [1: "dev-y", 2: "dev-z"]
        let letters = SessionTag.boxLetters(for: names, overrides: [1: "🦊"])
        XCTAssertEqual(letters[1], "🦊")
        // The neighbour still gets its common-prefix-stripped letter — the
        // override applies AFTER derivation.
        XCTAssertEqual(letters[2], "Z")

        // An override for a box not in the roster changes nothing.
        XCTAssertEqual(SessionTag.boxLetters(for: names, overrides: [99: "Q"]),
                       [1: "Y", 2: "Z"])
    }
}
