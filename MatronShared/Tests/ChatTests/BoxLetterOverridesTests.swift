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

    /// Seeds the legacy dictionary the way the pre-sync app wrote it.
    private func seedLegacy(_ overrides: [Int64: String]) {
        defaults.set(Dictionary(uniqueKeysWithValues: overrides.map { (String($0.key), $0.value) }),
                     forKey: BoxLetterOverrides.defaultsKey)
    }

    func testAllReadsLegacyEntriesAndRemoveDropsKeyWithLastOne() {
        seedLegacy([7: "q", 9: "z"])
        XCTAssertEqual(BoxLetterOverrides.all(from: defaults), [7: "q", 9: "z"])

        BoxLetterOverrides.remove(id: 7, from: defaults)
        XCTAssertEqual(BoxLetterOverrides.all(from: defaults), [9: "z"])
        // The last removal drops the whole defaults key — a migrated
        // install carries no residue.
        BoxLetterOverrides.remove(id: 9, from: defaults)
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

    // MARK: Migration

    func testMigrationPushesUntaggedBoxesAndClearsEntries() async {
        seedLegacy([7: "q", 9: "z"])
        nonisolated(unsafe) var pushed: [(Int64, String)] = []
        // Box 7 has no journal tag → pushed. Box 9 already has one → the
        // journal value wins, the relic is dropped without a push.
        await BoxLetterMigration.run(defaults: defaults,
                                     serverTags: [7: nil, 9: "b"]) { id, letter in
            pushed.append((id, letter))
        }
        XCTAssertEqual(pushed.count, 1)
        XCTAssertEqual(pushed.first?.0, 7)
        XCTAssertEqual(pushed.first?.1, "q")
        XCTAssertNil(defaults.object(forKey: BoxLetterOverrides.defaultsKey),
                     "every entry resolved — the key must be gone")
    }

    func testMigrationDropsEntriesForRevokedBoxesWithoutPushing() async {
        seedLegacy([42: "x"])
        nonisolated(unsafe) var pushes = 0
        // Box 42 is absent from serverTags entirely (revoked): no push, but
        // the dead entry still clears.
        await BoxLetterMigration.run(defaults: defaults, serverTags: [7: nil]) { _, _ in
            pushes += 1
        }
        XCTAssertEqual(pushes, 0)
        XCTAssertNil(defaults.object(forKey: BoxLetterOverrides.defaultsKey))
    }

    func testMigrationKeepsEntryWhenPushFailsSoNextLaunchRetries() async {
        seedLegacy([7: "q"])
        struct Offline: Error {}
        await BoxLetterMigration.run(defaults: defaults, serverTags: [7: nil]) { _, _ in
            throw Offline()
        }
        XCTAssertEqual(BoxLetterOverrides.all(from: defaults), [7: "q"],
                       "a failed push must leave the entry for the next launch")
    }
}
