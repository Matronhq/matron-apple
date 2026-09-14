import AppKit
import SwiftUI

/// The "recording" indicator that floats in the top-right corner of the
/// main screen for exactly as long as a voice note is being captured.
/// A panel rather than a notification banner: banners dismiss themselves
/// after a few seconds and need the notification permission, while this
/// stays until the note stops, shows the running time, and never steals
/// focus from whatever the user is speaking about (`nonactivatingPanel`,
/// `.floating` level, ignores mouse events).
@MainActor
final class VoiceNoteRecordingPanel {
    private var panel: NSPanel?

    func show(start: Date, hotkey: VoiceNoteHotkeyKey) {
        let content = VoiceNoteRecordingIndicator(start: start, hotkey: hotkey)
        let hosting = NSHostingView(rootView: content)
        hosting.frame.size = hosting.fittingSize
        let panel = self.panel ?? Self.makePanel()
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let inset: CGFloat = 16
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - inset,
                y: visible.maxY - panel.frame.height - inset))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }
}

struct VoiceNoteRecordingIndicator: View {
    let start: Date
    let hotkey: VoiceNoteHotkeyKey

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
            Text("Recording")
                .font(.headline)
            Text(start, style: .timer)
                .font(.headline.monospacedDigit())
            if hotkey != .off {
                Text("\(hotkey.label) to send")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fixedSize()
    }
}
