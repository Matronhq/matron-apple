import XCTest
@testable import Matron

/// Spec §3: `chat.timeline.uikit` is on by default in Debug and TestFlight
/// builds, off in App Store builds, and switchable in Settings ▸ Advanced.
final class ChatTimelineFlagTests: XCTestCase {
    func test_key_isTheSpecKey() {
        XCTAssertEqual(ChatTimelineFlag.key, "chat.timeline.uikit")
    }

    func test_debugAndTestFlightDefaultOn_appStoreDefaultsOff() {
        XCTAssertTrue(ChatTimelineFlag.defaultValue(for: .debug))
        XCTAssertTrue(ChatTimelineFlag.defaultValue(for: .testFlight))
        XCTAssertFalse(ChatTimelineFlag.defaultValue(for: .appStore))
    }

    func test_channel_readsTheBuildAndTheReceipt() {
        XCTAssertEqual(ChatTimelineFlag.channel(isDebugBuild: true, receiptURL: nil), .debug)
        XCTAssertEqual(ChatTimelineFlag.channel(
            isDebugBuild: false, receiptURL: URL(fileURLWithPath: "/c/StoreKit/sandboxReceipt")), .testFlight)
        XCTAssertEqual(ChatTimelineFlag.channel(
            isDebugBuild: false, receiptURL: URL(fileURLWithPath: "/c/StoreKit/receipt")), .appStore)
        XCTAssertEqual(ChatTimelineFlag.channel(isDebugBuild: false, receiptURL: nil), .appStore)
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
