import XCTest
@testable import MatronEvents

final class DiffEventTests: XCTestCase {
    func testParseRichPayload() {
        let evt = DiffEvent.parse(payload: [
            "file_path": "/Users/dan/Dev/x/Sources/A.swift",
            "display_path": "Sources/A.swift",
            "viewer_url": "https://viewer.example/view?token=abc",
            "tool": "Edit",
            "label": "code-reviewer",
            "diff": "@@ -1,1 +1,1 @@\n-a\n+b",
            "added": 1, "removed": 1,
            "truncated": true, "new_file": false,
        ])
        XCTAssertEqual(evt.filePath, "/Users/dan/Dev/x/Sources/A.swift")
        XCTAssertEqual(evt.displayPath, "Sources/A.swift")
        XCTAssertEqual(evt.viewerURL?.host, "viewer.example")
        XCTAssertEqual(evt.tool, "Edit")
        XCTAssertEqual(evt.label, "code-reviewer")
        XCTAssertEqual(evt.diff, "@@ -1,1 +1,1 @@\n-a\n+b")
        XCTAssertEqual(evt.added, 1)
        XCTAssertEqual(evt.removed, 1)
        XCTAssertTrue(evt.truncated)
        XCTAssertFalse(evt.newFile)
        XCTAssertEqual(evt.filename, "A.swift")
    }

    func testParseBareLegacyShape() {
        // Pre-spec payloads carried only a diff string (or `snippet`).
        let evt = DiffEvent.parse(payload: ["diff": "+added line"])
        XCTAssertEqual(evt.diff, "+added line")
        XCTAssertNil(evt.filePath)
        XCTAssertNil(evt.viewerURL)
        XCTAssertNil(evt.added)
        XCTAssertFalse(evt.truncated)
        XCTAssertNil(evt.filename)
    }

    func testParseSnippetFallbackAndEmpty() {
        XCTAssertEqual(DiffEvent.parse(payload: ["snippet": "+x"]).diff, "+x")
        // Total parse: an empty payload yields an empty diff, never nil —
        // the card renders header-only.
        XCTAssertEqual(DiffEvent.parse(payload: [:]).diff, "")
    }

    func testFilenameFallsBackToFilePath() {
        let evt = DiffEvent.parse(payload: ["diff": "x", "file_path": "/a/b/c.txt"])
        XCTAssertEqual(evt.filename, "c.txt")
    }

    func testNonStringViewerURLIgnored() {
        let evt = DiffEvent.parse(payload: ["diff": "x", "viewer_url": 42])
        XCTAssertNil(evt.viewerURL)
    }
}
