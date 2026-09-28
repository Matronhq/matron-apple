import XCTest
@testable import Matron

/// Spec §3: `chat.timeline.uikit` is on by default in every build, and
/// switchable in Settings ▸ Advanced.
final class ChatTimelineFlagTests: XCTestCase {
    func test_key_isTheSpecKey() {
        XCTAssertEqual(ChatTimelineFlag.key, "chat.timeline.uikit")
    }

    /// Dan, 2026-09-28: the UIKit timeline ships in the next App Store
    /// release. There is no per-channel default any more, so an App Store
    /// install that never touched the toggle gets it too.
    func test_defaultsOn() {
        XCTAssertTrue(ChatTimelineFlag.defaultValue)
    }

    /// Someone who switched it off keeps the SwiftUI timeline.
    func test_aStoredChoiceBeatsTheDefault() throws {
        let suite = "ChatTimelineFlagTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(ChatTimelineFlag.isOn(in: defaults))
        defaults.set(false, forKey: ChatTimelineFlag.key)
        XCTAssertFalse(ChatTimelineFlag.isOn(in: defaults))
    }

    /// Source pin: Settings ▸ Advanced carries the toggle on the flag's key.
    func test_settingsOffersTheToggle() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Matron/Features/Settings/DeviceSettingsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("@AppStorage(ChatTimelineFlag.key)"))
        XCTAssertTrue(source.contains("Text(\"Advanced\")"))
        XCTAssertTrue(source.contains("settings.uikitTimeline"))
    }
}
