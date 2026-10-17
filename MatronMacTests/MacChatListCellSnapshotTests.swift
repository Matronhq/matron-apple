#if os(macOS)
import XCTest
import AppKit
@testable import MatronMac

/// The native sidebar against today's SwiftUI sidebar, on the same
/// fixtures, light and dark: both lists are rendered off-screen, and every
/// row's frame and the box around what it draws (its text and badges) must
/// agree within two points.
///
/// Compares two renders made on the same machine rather than stored
/// images, so it holds on any macOS version and runs with the snapshot
/// tests skipped.
@MainActor
final class MacChatListCellSnapshotTests: XCTestCase {
    static let tolerance: CGFloat = 2
    static let headerTrailingTolerance: CGFloat = 4

    func compare(_ appearance: NSAppearance.Name, file: StaticString = #filePath, line: UInt = #line) {
        let now = Date()
        let fixtures = MacSidebarFixtures.rows(now: now)
        let size = NSSize(width: 280, height: 860)
        let swiftUI = MacSidebarRender.swiftUI(fixtures, now: now, selected: "c2", appearance: appearance, size: size)
        let appKit = MacSidebarRender.appKit(fixtures, now: now, selected: "c2", appearance: appearance, size: size)
        let name = appearance == .darkAqua ? "dark" : "light"

        XCTAssertEqual(swiftUI.rows.map(\.isHeader), appKit.rows.map(\.isHeader),
                       "\(name): the same headers and rows in the same order", file: file, line: line)
        XCTAssertEqual(appKit.rows.count, fixtures.count + MacSidebarFixtures.grouped(fixtures, now: now).count,
                       file: file, line: line)
        for (index, (s, a)) in zip(swiftUI.rows, appKit.rows).enumerated() {
            let what = "\(name) row \(index)\(s.isHeader ? " (header)" : "")"
            XCTAssertEqual(a.rect.minY, s.rect.minY, accuracy: Self.tolerance, "\(what): top", file: file, line: line)
            XCTAssertEqual(a.rect.height, s.rect.height, accuracy: 1, "\(what): height", file: file, line: line)
            guard let inkS = swiftUI.inkBox(in: s.rect), let inkA = appKit.inkBox(in: a.rect) else {
                XCTFail("\(what): nothing drawn", file: file, line: line)
                continue
            }
            // Relative to the row, so one row's height cannot fail the rest.
            XCTAssertEqual(inkA.minX, inkS.minX, accuracy: Self.tolerance, "\(what): leading", file: file, line: line)
            // Headers keep the source list's own group-row font (slightly
            // wider than SwiftUI's header): their text may end a little later.
            XCTAssertEqual(inkA.maxX, inkS.maxX, accuracy: s.isHeader ? Self.headerTrailingTolerance : Self.tolerance,
                           "\(what): trailing", file: file, line: line)
            XCTAssertEqual(inkA.minY - a.rect.minY, inkS.minY - s.rect.minY, accuracy: Self.tolerance,
                           "\(what): ink top", file: file, line: line)
            XCTAssertEqual(inkA.maxY - a.rect.minY, inkS.maxY - s.rect.minY, accuracy: Self.tolerance,
                           "\(what): ink bottom", file: file, line: line)
        }
    }

    func test_nativeCell_matchesTheSwiftUIRow_light() { compare(.aqua) }

    func test_nativeCell_matchesTheSwiftUIRow_dark() { compare(.darkAqua) }
}
#endif
