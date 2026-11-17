#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronDesignSystem
import MatronModels

/// Renders the voice-note recording surfaces to PNGs for review: the item
/// reply bar, the app-wide pill, the floating panel, and the row for a note
/// with nothing in it. Writes only when `MATRON_RENDER_DIR` names a
/// directory (`TEST_RUNNER_MATRON_RENDER_DIR` under xcodebuild); otherwise
/// it skips.
@MainActor
final class VoiceNoteRecordingRenderHarness: XCTestCase {
    private let mics = [Microphone(id: "built-in", name: "MacBook Pro Microphone"),
                        Microphone(id: "usb", name: "USB Desk Microphone")]

    private func directory() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MATRON_RENDER_DIR"] ?? env["TEST_RUNNER_MATRON_RENDER_DIR"] else {
            throw XCTSkip("set MATRON_RENDER_DIR to render")
        }
        return URL(fileURLWithPath: path)
    }

    private func write<V: View>(_ view: V, _ name: String, to dir: URL) {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let host = MacSnapshotHost(view.frame(width: 560).padding(12), appearance: appearance)
            defer { host.close() }
            try? host.pngData()?.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }

    func test_render() throws {
        let dir = try directory()
        let start = Date().addingTimeInterval(-31)
        let menu = MicrophoneMenu(current: mics[0], available: mics, preferredID: nil,
                                  defaultTitle: "System default", onSelect: { _ in })
        write(MacItemVoiceNoteBar(start: start, onCancel: {}) { EmptyView() }, "item-bar-before", to: dir)
        write(MacItemVoiceNoteBar(start: start, onCancel: {}) { menu }, "item-bar-after", to: dir)
        write(MacItemVoiceNoteBar(start: nil, onCancel: {}) { menu }, "item-bar-starting-after", to: dir)
        write(VoiceNoteIndicator(mode: .recording(start: start), title: "Weekend trip itinerary",
                                 onOpen: {}, onCancel: {}, onSend: {}), "pill-before", to: dir)
        write(VoiceNoteIndicator(mode: .recording(start: start), title: "Weekend trip itinerary",
                                 microphone: mics[0].name, onOpen: {}, onCancel: {}, onSend: {}), "pill-after", to: dir)
        write(VoiceNoteRecordingIndicator(start: start, hotkey: .default), "panel-before", to: dir)
        write(VoiceNoteRecordingIndicator(start: start, hotkey: .default, microphone: mics[0].name),
              "panel-after", to: dir)
        write(VoiceNoteIndicator(mode: .failed(message: "Nothing was recorded, try again", canRetry: false),
                                 title: "Weekend trip itinerary",
                                 onOpen: {}, onCancel: {}, onSend: {}), "empty-refused", to: dir)
        write(VoiceNoteIndicator(mode: .failed(message: "MacBook Pro Microphone stopped at 0:12. Retry sends what was recorded.", canRetry: true),
                                 title: "Weekend trip itinerary",
                                 onOpen: {}, onCancel: {}, onSend: {}), "capture-lost", to: dir)
    }
}
#endif
