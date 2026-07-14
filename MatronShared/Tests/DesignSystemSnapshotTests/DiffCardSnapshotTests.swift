import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem
import MatronEvents

final class DiffCardSnapshotTests: XCTestCase {
    private func sampleEvent(
        diff: String = "@@ -10,3 +10,4 @@\n context line\n-let b = 2\n+let b = 99\n+let b2 = 100\n context line",
        label: String? = nil, truncated: Bool = false, newFile: Bool = false,
        viewer: String? = "https://v.example/view?token=t"
    ) -> DiffEvent {
        DiffEvent(filePath: "/w/Sources/A.swift", displayPath: "Sources/A.swift",
                  viewerURL: viewer.flatMap(URL.init(string:)), tool: "Edit",
                  label: label, diff: diff, added: 2, removed: 1,
                  truncated: truncated, newFile: newFile)
    }

    func test_collapsed_smallDiff() {
        assertVariants(of: DiffCard(event: sampleEvent()).frame(width: 420),
                       named: "collapsed_small")
    }

    func test_collapsed_longDiff_showsMoreLinesRow() {
        let long = (0..<30).map { "+added line \($0)" }.joined(separator: "\n")
        assertVariants(of: DiffCard(event: sampleEvent(diff: long)).frame(width: 420),
                       named: "collapsed_more_lines")
    }

    func test_collapsed_truncated_smallDiff_showsHeaderMarker() {
        // A byte-cap-truncated diff that FITS the 12 collapsed lines must
        // still show a truncation cue while collapsed — the dimmed "…" in
        // the header (5a7efc0; bugbot "truncation invisible when collapsed
        // and diff fits").
        assertVariants(of: DiffCard(event: sampleEvent(truncated: true)).frame(width: 420),
                       named: "collapsed_truncated_small")
    }

    func test_expanded_truncated_showsTruncationRow() {
        let long = (0..<20).map { "+added line \($0)" }.joined(separator: "\n")
        assertVariants(of: DiffCard(event: sampleEvent(diff: long, truncated: true),
                                    expanded: true).frame(width: 420),
                       named: "expanded_truncated")
    }

    func test_newFile_badge() {
        assertVariants(of: DiffCard(event: sampleEvent(newFile: true)).frame(width: 420),
                       named: "new_file")
    }

    func test_subagentLabel_inHeader() {
        assertVariants(of: DiffCard(event: sampleEvent(label: "code-reviewer")).frame(width: 420),
                       named: "subagent_label")
    }

    func test_noViewerURL_plainFilename() {
        assertVariants(of: DiffCard(event: sampleEvent(viewer: nil)).frame(width: 420),
                       named: "no_viewer_url")
    }
}
