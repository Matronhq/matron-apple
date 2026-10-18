#if os(macOS)
import XCTest
import AppKit
@testable import MatronMac

/// The native items pane rows against today's SwiftUI `ItemsListView`, on
/// the same fixtures, light and dark, in both scopes: both lists are
/// rendered off-screen, and every row's (and header's) height, place and
/// the box around what it draws must agree within two points.
///
/// Compares two renders made on the same machine rather than stored
/// images, so it holds on any macOS version and runs with the snapshot
/// tests skipped.
@MainActor
final class MacItemsPaneNativeRowsTests: XCTestCase {
    static let tolerance: CGFloat = 2

    func compare(_ appearance: NSAppearance.Name, all: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let size = NSSize(width: 380, height: 900)
        let swiftUI = MacItemsPaneRender.swiftUI(all: all, appearance: appearance, size: size)
        let appKit = MacItemsPaneRender.appKit(all: all, appearance: appearance, size: size)
        let name = "\(appearance == .darkAqua ? "dark" : "light") \(all ? "All" : "This chat")"
        XCTAssertEqual(swiftUI.rows.count, appKit.rows.count, "\(name): the same rows", file: file, line: line)
        guard let topS = swiftUI.rows.first?.rect.minY, let topA = appKit.rows.first?.rect.minY else { return }
        for (index, (s, a)) in zip(swiftUI.rows, appKit.rows).enumerated() {
            let what = "\(name) row \(index)"
            // A header's spacing sits above it in the AppKit list: compare
            // where each row ends, from the list's top.
            XCTAssertEqual(a.rect.maxY - topA, s.rect.maxY - topS, accuracy: 1, "\(what): bottom", file: file, line: line)
            // The AppKit table says which rows are headers; the SwiftUI
            // one is only guessed at by height.
            guard !a.isHeader else { continue }
            XCTAssertEqual(a.rect.height, s.rect.height, accuracy: 1, "\(what): height", file: file, line: line)
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

    func test_nativeRows_matchTheSwiftUIList_thisChat_light() { compare(.aqua, all: false) }
    func test_nativeRows_matchTheSwiftUIList_thisChat_dark() { compare(.darkAqua, all: false) }
    func test_nativeRows_matchTheSwiftUIList_all_light() { compare(.aqua, all: true) }
    func test_nativeRows_matchTheSwiftUIList_all_dark() { compare(.darkAqua, all: true) }
}
#endif
