import XCTest
import SwiftUI
import UIKit
import MatronChat
import MatronModels
import MatronViewModels
@testable import Matron

/// The chat screen has one timeline, the UIKit one (Dan, 2026-09-28: people
/// should not be choosing between two, and the SwiftUI one is removed
/// rather than hidden).
@MainActor
final class ChatTimelineIntegrationTests: XCTestCase {
    /// The key of the Settings toggle that 1.1.1 try builds and 1.2.0 (1036)
    /// carried. Nothing reads it any more.
    private static let retiredFlagKey = "chat.timeline.uikit"

    private func host(storing stored: Bool? = nil) async throws -> (UIWindow, ChatViewModel) {
        if let stored {
            UserDefaults.standard.set(stored, forKey: Self.retiredFlagKey)
            addTeardownBlock { UserDefaults.standard.removeObject(forKey: Self.retiredFlagKey) }
        }
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

    func test_chat_mountsTheUIKitTimeline() async throws {
        let (window, _) = try await host()
        try await waitUntil(timeout: 5) { self.timeline(in: window) != nil }
        XCTAssertNotNil(timeline(in: window))
    }

    /// Someone who switched the old toggle off must not be left on a
    /// timeline that no longer exists, or on none.
    func test_chat_mountsTheUIKitTimeline_whateverAnEarlierBuildStored() async throws {
        let (window, _) = try await host(storing: false)
        try await waitUntil(timeout: 5) { self.timeline(in: window) != nil }
        XCTAssertNotNil(timeline(in: window))
    }

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Source pin: `ChatView` holds no SwiftUI timeline and no switch
    /// between two. The read-only `SubChatView`, further down the same
    /// file, still scrolls the SwiftUI rows and is not covered here.
    func test_chatView_hasNoSwiftUITimelineLeft() throws {
        let file = try source("Matron/Features/Chat/ChatView.swift")
        let chatViewEnd = try XCTUnwrap(file.range(of: "\nprivate struct TimelineListContent"))
        let chatView = String(file[..<chatViewEnd.lowerBound])
        XCTAssertTrue(chatView.contains("struct ChatView: View"))
        XCTAssertTrue(chatView.contains("ChatTimelineView("))
        XCTAssertFalse(chatView.contains("ScrollViewReader"))
        XCTAssertFalse(chatView.contains("usesUIKitTimeline"))
        XCTAssertFalse(chatView.contains("ChatTimelineFlag"))
    }

    /// Source pin: Settings offers no timeline toggle.
    func test_settingsOffersNoTimelineToggle() throws {
        let settings = try source("Matron/Features/Settings/DeviceSettingsView.swift")
        XCTAssertFalse(settings.contains("ChatTimelineFlag"))
        XCTAssertFalse(settings.contains("settings.uikitTimeline"))
        XCTAssertFalse(settings.contains("New chat timeline"))
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
