import XCTest
import SwiftUI
import UIKit
import MatronChat
import MatronModels
import MatronViewModels
@testable import Matron

/// Spec §3: the flag picks the timeline in a development build (which the
/// test host is); the SwiftUI path stays untouched until it is deleted.
@MainActor
final class ChatTimelineIntegrationTests: XCTestCase {
    private func host(flag: Bool) async throws -> (UIWindow, ChatViewModel) {
        UserDefaults.standard.set(flag, forKey: ChatTimelineFlag.key)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: ChatTimelineFlag.key) }
        let service = LiveTimelineFixture()
        service.emit(TimelineFixtures.conversation(12))
        let viewModel = TimelineFixtures.viewModel(service)
        let view = ChatView(
            viewModel: viewModel,
            composerVM: ComposerViewModel(roomID: viewModel.roomID, timeline: service, commands: []),
            stripViewModel: SubChatStripViewModel(chat: NoChildrenChatFixture(), parentConvoID: viewModel.roomID),
            chatTitle: "Integration")
        // A scene-less window never renders SwiftUI into UIKit views; attach
        // to the test host's scene (same as AppShellViewTests.renderInWindow).
        let frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        addTeardownBlock { window.isHidden = true }
        window.rootViewController = UIHostingController(rootView: NavigationStack { view })
        window.makeKeyAndVisible()
        try await waitUntil(timeout: 5) { !viewModel.rows.isEmpty }
        return (window, viewModel)
    }

    private func timeline(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView, collection.accessibilityIdentifier == "chat.timeline" {
            return collection
        }
        for subview in view.subviews {
            if let found = timeline(in: subview) { return found }
        }
        return nil
    }

    func test_flagOn_mountsTheUIKitTimeline() async throws {
        let (window, _) = try await host(flag: true)
        try await waitUntil(timeout: 5) { self.timeline(in: window) != nil }
        XCTAssertNotNil(timeline(in: window))
    }

    func test_flagOff_keepsTheSwiftUITimeline() async throws {
        let (window, _) = try await host(flag: false)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(timeline(in: window))
    }

    /// Source pin: the SwiftUI branch is still there, untouched, behind the flag.
    func test_swiftUIBranch_isUnchanged() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Matron/Features/Chat/ChatView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let branch = try XCTUnwrap(source.range(of: "} else if usesUIKitTimeline {"))
        let reader = try XCTUnwrap(source.range(of: "ScrollViewReader { proxy in"))
        XCTAssertLessThan(branch.lowerBound, reader.lowerBound)
        XCTAssertTrue(source.contains(".defaultScrollAnchor(sizeChangeAnchor, for: .sizeChanges)"))
        // No `@AppStorage`: a stored choice must not reach a shipped build.
        XCTAssertFalse(source.contains("@AppStorage(ChatTimelineFlag.key)"))
        XCTAssertTrue(source.contains("private var usesUIKitTimeline: Bool { ChatTimelineFlag.isOn() }"))
    }

    func test_hostedEnvironment_carriesTheLinkHandlers() {
        var environment = EnvironmentValues()
        environment.openTrackerItem = { _ in }
        environment.openConversation = { _ in }
        let hosted = TimelineHostedEnvironment(environment)
        XCTAssertNotNil(hosted.openTrackerItem)
        XCTAssertNotNil(hosted.openConversation)
    }
}
