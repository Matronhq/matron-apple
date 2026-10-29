#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac

/// The AppKit lists, timeline and item thread answer SwiftUI's size
/// questions with the space they are offered, without measuring the
/// AppKit view inside.
@MainActor
final class FillingRepresentableSizeTests: XCTestCase {
    func test_size_isTheProposal_withSwiftUIsDefaultWhereItIsOpen() {
        XCTAssertEqual(FillingRepresentableSize.size(for: ProposedViewSize(width: 320, height: 640)),
                       CGSize(width: 320, height: 640))
        XCTAssertEqual(FillingRepresentableSize.size(for: .zero), .zero)
        XCTAssertEqual(FillingRepresentableSize.size(for: .infinity),
                       CGSize(width: CGFloat.infinity, height: .infinity))
        XCTAssertEqual(FillingRepresentableSize.size(for: .unspecified), CGSize(width: 10, height: 10))
        XCTAssertEqual(FillingRepresentableSize.size(for: ProposedViewSize(width: 200, height: nil)),
                       CGSize(width: 200, height: 10))
    }

    /// A list still takes the whole of the space it is given.
    func test_aList_fillsItsSpace() {
        let list = MacListView(rows: MacDecisionsRows(), selection: .constant(Set<String>()),
                               accessibilityIdentifier: "test.list", publications: { AsyncStream { _ in } })
        let controller = NSHostingController(rootView: list)
        for size in [CGSize(width: 260, height: 400), CGSize(width: 900, height: 120)] {
            XCTAssertEqual(controller.sizeThatFits(in: size), size)
        }
    }
}
#endif
