import XCTest
@testable import Matron

/// App shell (spec §3): the Coordinator tab.
final class CoordinatorTabViewTests: XCTestCase {
    /// The root depends only on the setting — setup view without one, the
    /// chat with one.
    func test_root_isSetupWithoutASetting_andTheChatWithOne() {
        XCTAssertEqual(CoordinatorTabView.root(for: nil), .setup)
        XCTAssertEqual(CoordinatorTabView.root(for: ""), .setup, "an empty stored value is no coordinator")
        XCTAssertEqual(CoordinatorTabView.root(for: "cv_1"), .chat("cv_1"))
    }

    /// The tab's ROOT chat is titled "Coordinator" (the rule itself is
    /// `ChatView.headerTitle`, pinned in `ChatPagerTests`).
    /// SwiftUI bar items expose neither labels nor a stable count to UIKit
    /// in a unit-test host (probed 2026-09-24: an ordinary pushed chat and
    /// the Coordinator root both report four trailing items), so this pins
    /// the source contract: the flag is set in the `.chat` root branch, and
    /// nowhere else in the file — a pushed chat keeps its own title.
    func test_rootChat_andOnlyTheRootChat_isTitledCoordinator() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Matron/Features/Coordinator/CoordinatorTabView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let flag = ".environment(\\.isCoordinatorRootChat, true)"
        XCTAssertEqual(source.components(separatedBy: flag).count - 1, 1, "set exactly once")
        guard let branch = source.range(of: "case .chat(let id):"),
              let destinations = source.range(of: ".navigationDestination(for: String.self)") else {
            return XCTFail("CoordinatorTabView's root switch not found — move this pin alongside any rename")
        }
        let root = source[branch.upperBound..<destinations.lowerBound]
        XCTAssertTrue(root.contains(flag), "the Coordinator's root chat must carry the root-chat flag")
    }
}
