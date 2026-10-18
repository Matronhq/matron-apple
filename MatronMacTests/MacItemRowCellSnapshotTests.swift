#if os(macOS)
import XCTest
import AppKit
@testable import MatronMac

/// The native For you rows against today's SwiftUI `DecisionsListView`, on
/// the same fixtures, light and dark, both tabs: both lists are rendered
/// off-screen, and every row's height and the box around what it draws
/// (glyph, text, Seen button, image) must agree within two points.
///
/// Compares two renders made on the same machine rather than stored
/// images, so it holds on any macOS version and runs with the snapshot
/// tests skipped.
@MainActor
final class MacItemRowCellSnapshotTests: XCTestCase {
    static let tolerance: CGFloat = 2

    func compare(_ appearance: NSAppearance.Name, open: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let size = NSSize(width: 380, height: 640)
        let swiftUI = MacDecisionsRender.swiftUI(open: open, appearance: appearance, size: size)
        let appKit = MacDecisionsRender.appKit(open: open, appearance: appearance, size: size)
        let name = "\(appearance == .darkAqua ? "dark" : "light") \(open ? "Needs you" : "Done")"
        XCTAssertEqual(swiftUI.rows.count, appKit.rows.count, "\(name): the same rows", file: file, line: line)
        for (index, (s, a)) in zip(swiftUI.rows, appKit.rows).enumerated() {
            let what = "\(name) row \(index)"
            XCTAssertEqual(a.rect.height, s.rect.height, accuracy: 1, "\(what): height", file: file, line: line)
            // Clear of the hairlines at the row's edges.
            guard let inkS = swiftUI.inkBox(in: s.rect.insetBy(dx: 0, dy: 1)),
                  let inkA = appKit.inkBox(in: a.rect.insetBy(dx: 0, dy: 1)) else {
                XCTFail("\(what): nothing drawn", file: file, line: line)
                continue
            }
            XCTAssertEqual(inkA.minX, inkS.minX, accuracy: Self.tolerance, "\(what): leading", file: file, line: line)
            XCTAssertEqual(inkA.maxX, inkS.maxX, accuracy: Self.tolerance, "\(what): trailing", file: file, line: line)
            XCTAssertEqual(inkA.minY - a.rect.minY, inkS.minY - s.rect.minY, accuracy: Self.tolerance,
                           "\(what): ink top", file: file, line: line)
            XCTAssertEqual(inkA.maxY - a.rect.minY, inkS.maxY - s.rect.minY, accuracy: Self.tolerance,
                           "\(what): ink bottom", file: file, line: line)
        }
    }

    func test_nativeRows_matchTheSwiftUIList_needsYou_light() { compare(.aqua, open: true) }
    func test_nativeRows_matchTheSwiftUIList_needsYou_dark() { compare(.darkAqua, open: true) }
    func test_nativeRows_matchTheSwiftUIList_done_light() { compare(.aqua, open: false) }
    func test_nativeRows_matchTheSwiftUIList_done_dark() { compare(.darkAqua, open: false) }
}
#endif
