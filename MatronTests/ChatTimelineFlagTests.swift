import XCTest
@testable import Matron

/// The UIKit timeline is the chat timeline (Dan, 2026-09-28: people should
/// not be choosing between two). A shipped build has no way to the SwiftUI
/// one; development and perf-probe builds keep `chat.timeline.uikit` until
/// that code is deleted, for the perf baseline and its tests.
final class ChatTimelineFlagTests: XCTestCase {
    private func defaults(storing value: Bool?) throws -> UserDefaults {
        let suite = "ChatTimelineFlagTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        if let value { defaults.set(value, forKey: ChatTimelineFlag.key) }
        return defaults
    }

    func test_key_isTheSpecKey() {
        XCTAssertEqual(ChatTimelineFlag.key, "chat.timeline.uikit")
    }

    /// Someone who switched the old toggle off under 1.1.1 must not be left
    /// on the SwiftUI timeline with no toggle to switch back.
    func test_aShippedBuild_usesTheUIKitTimeline_whateverIsStored() throws {
        for stored in [nil, true, false] as [Bool?] {
            XCTAssertTrue(ChatTimelineFlag.isOn(in: try defaults(storing: stored), developmentBuild: false),
                          "stored \(String(describing: stored))")
        }
    }

    func test_aDevelopmentBuild_defaultsToTheUIKitTimeline() throws {
        XCTAssertTrue(ChatTimelineFlag.isOn(in: try defaults(storing: nil), developmentBuild: true))
    }

    func test_aDevelopmentBuild_canStillReachTheSwiftUITimeline() throws {
        XCTAssertFalse(ChatTimelineFlag.isOn(in: try defaults(storing: false), developmentBuild: true))
    }

    /// Source pin: Settings offers no timeline toggle.
    func test_settingsOffersNoTimelineToggle() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Matron/Features/Settings/DeviceSettingsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("ChatTimelineFlag"))
        XCTAssertFalse(source.contains("settings.uikitTimeline"))
        XCTAssertFalse(source.contains("New chat timeline"))
    }
}
