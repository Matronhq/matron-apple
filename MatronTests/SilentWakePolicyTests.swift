import XCTest
@testable import Matron

final class SilentWakePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testFirstWakeInTheBackgroundCatchesUp() {
        XCTAssertTrue(SilentWakePolicy.shouldCatchUp(inBackground: true, lastCatchUpEnded: nil, now: now))
    }

    func testInFrontTheLiveSocketAlreadyHasIt() {
        XCTAssertFalse(SilentWakePolicy.shouldCatchUp(inBackground: false, lastCatchUpEnded: nil, now: now))
    }

    func testAWakeSoonAfterACatchUpEndsStraightAway() {
        let recent = now.addingTimeInterval(-(SilentWakePolicy.minimumGap - 1))
        XCTAssertFalse(SilentWakePolicy.shouldCatchUp(inBackground: true, lastCatchUpEnded: recent, now: now))
    }

    func testAWakeAfterTheGapCatchesUp() {
        let old = now.addingTimeInterval(-SilentWakePolicy.minimumGap)
        XCTAssertTrue(SilentWakePolicy.shouldCatchUp(inBackground: true, lastCatchUpEnded: old, now: now))
    }
}
