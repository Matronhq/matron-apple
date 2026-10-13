import XCTest
import SwiftUI
import UIKit
@testable import MatronDesignSystem
import MatronModels
@testable import Matron

/// The Projects filter field must never hold on to the keyboard: opening a
/// page drops it, and coming back does not bring it up again. Rendered in a
/// scene-attached `UIWindow` so the field is a real `UITextField`.
@MainActor
final class ProjectsFilterKeyboardTests: XCTestCase {
    private var window: UIWindow!

    override func tearDown() async throws {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        try await super.tearDown()
    }

    @Observable final class Stack {
        var path: [String] = []
    }

    private struct Host: View {
        @Bindable var stack: Stack
        let home: ProjectsHomeView
        var body: some View {
            NavigationStack(path: $stack.path) {
                home.navigationTitle("Projects").navigationDestination(for: String.self) { Text($0) }
            }
        }
    }

    static var home: ProjectsHomeSnapshot {
        let project = Project(id: "pj_1", num: 1, title: "Docs site launch", body: "", status: "On track.",
                              statusBy: .agent, statusUpdatedAt: Date(), missions: ProjectMissionCounts(running: 1),
                              lastActivityAt: Date())
        return ProjectsHomeSnapshot(cards: [ProjectCard(project: project)])
    }

    private func mount() throws -> (stack: Stack, home: ProjectsHomeView) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let stack = Stack()
        let home = ProjectsHomeView(model: .init(home: Self.home, isRefreshing: false),
                                    onAction: { _ in stack.path = ["page"] }, onRefresh: {})
        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Host(stack: stack, home: home))
        window.makeKeyAndVisible()
        settle()
        return (stack, home)
    }

    private func settle(_ seconds: TimeInterval = 1) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
        }
    }

    private func fields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(fields(in:))
    }

    private var focusedField: UITextField? { fields(in: window).first(where: \.isFirstResponder) }

    private func focusTheFilter() throws {
        let field = try XCTUnwrap(fields(in: window).first, "the filter field is a text field")
        XCTAssertTrue(field.becomeFirstResponder())
        settle(0.5)
        XCTAssertNotNil(focusedField, "the filter field takes the keyboard")
    }

    func test_openingAProject_dropsTheKeyboard_andBackDoesNotBringItUp() throws {
        let (stack, home) = try mount()
        try focusTheFilter()

        // What a tapped card runs.
        home.onAction(.openProject("pj_1"))
        settle(1.5)
        XCTAssertEqual(stack.path, ["page"], "the card opens its page")
        XCTAssertNil(focusedField, "the pushed page has no keyboard")

        stack.path = []
        settle(2)
        XCTAssertNil(focusedField, "coming back does not focus the filter again")
    }

    func test_theSearchKey_dropsTheKeyboard() throws {
        _ = try mount()
        try focusTheFilter()
        let field = try XCTUnwrap(focusedField)
        if field.delegate?.textFieldShouldReturn?(field) != false { field.sendActions(for: .editingDidEndOnExit) }
        field.sendActions(for: .primaryActionTriggered)
        settle(0.5)
        XCTAssertNil(focusedField)
    }

    func test_scrollingThePage_dropsTheKeyboard() throws {
        _ = try mount()
        func scrollViews(in view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:))
        }
        let page = try XCTUnwrap(scrollViews(in: window).first { !($0 is UITextView) }, "the page scrolls")
        XCTAssertTrue([.onDrag, .onDragWithAccessory].contains(page.keyboardDismissMode))
    }
}
