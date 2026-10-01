import XCTest
@testable import Matron

/// `ProjectDetailHost.displayState` is the host's render-priority decision
/// pulled out as a pure function: a loaded page beats "not found", which
/// beats a failed load, which beats the spinner (shared fix 2's contract
/// for `ProjectDetailViewModel.loadFailed`).
final class ProjectDetailHostTests: XCTestCase {
    func testALoadedPageWinsOverEveryOtherFlag() {
        XCTAssertEqual(ProjectDetailHost.displayState(hasPage: true, isMissing: true, loadFailed: true), .page)
        XCTAssertEqual(ProjectDetailHost.displayState(hasPage: true, isMissing: false, loadFailed: false), .page)
    }

    func testMissingBeatsLoadFailedWhenThereIsNoPage() {
        XCTAssertEqual(ProjectDetailHost.displayState(hasPage: false, isMissing: true, loadFailed: true), .missing)
    }

    func testLoadFailedShowsOnlyWithNoPageAndNotMissing() {
        XCTAssertEqual(ProjectDetailHost.displayState(hasPage: false, isMissing: false, loadFailed: true), .loadFailed)
    }

    func testTheSpinnerIsTheFallbackWithNoFlagsSet() {
        XCTAssertEqual(ProjectDetailHost.displayState(hasPage: false, isMissing: false, loadFailed: false), .loading)
    }
}
