import XCTest
import UIKit
import SnapshotTesting

/// Light + dark snapshot of a UIKit view. Skipped when
/// `MATRON_SKIP_SNAPSHOT_TESTS=1` (local default via `scripts/ios-test.sh`,
/// and CI); `MATRON_RECORD_SNAPSHOTS=1` re-records. Baselines live under
/// `MatronTests/__Snapshots__/` (run `xcodegen generate` after recording new ones).
@MainActor
func assertTimelineSnapshot(_ view: UIView, size: CGSize, named name: String,
                            file: StaticString = #filePath, testName: String = #function, line: UInt = #line) {
    let environment = ProcessInfo.processInfo.environment
    guard environment["MATRON_SKIP_SNAPSHOT_TESTS"] != "1" else { return }
    let record: SnapshotTestingConfiguration.Record = environment["MATRON_RECORD_SNAPSHOTS"] == "1" ? .all : .missing
    withSnapshotTesting(record: record) {
        for (style, suffix) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            assertSnapshot(of: view, as: .image(size: size, traits: UITraitCollection(userInterfaceStyle: style)),
                           named: "\(name)-\(suffix)", file: file, testName: testName, line: line)
        }
    }
}
