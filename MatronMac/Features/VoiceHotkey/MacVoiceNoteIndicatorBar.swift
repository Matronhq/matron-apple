import SwiftUI
import MatronDesignSystem
import MatronViewModels

/// The app-wide voice-note pill (`VoiceNoteIndicator`, mission 5840) along
/// the bottom of the window's detail column: under a chat, an item, a
/// mission or project page alike, so the note's Cancel / Send — and a way
/// back to where it is going — follow the user while they browse. Hidden
/// while the composer the note belongs to is on screen with its own bar.
/// The floating `VoiceNoteRecordingPanel` still covers Matron being behind
/// another app.
struct MacVoiceNoteIndicatorBar: ViewModifier {
    let session: VoiceNoteSession?
    let onOpen: (VoiceNoteSession.Target.Kind) -> Void

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if let session, Self.hasRows(session) {
                VStack(spacing: 6) {
                    if session.showsIndicator, let target = session.target, let start = session.recordingStart {
                        VoiceNoteIndicator(mode: .recording(start: start), title: target.title,
                                           onOpen: { onOpen(target.kind) },
                                           onCancel: { session.cancel() },
                                           onSend: { session.stopAndSend() })
                    } else if let target = session.sendingTarget {
                        VoiceNoteIndicator(mode: .sending, title: target.title,
                                           onOpen: { onOpen(target.kind) }, onCancel: {}, onSend: {})
                    }
                    ForEach(session.failures) { failure in
                        VoiceNoteIndicator(mode: .failed(message: failure.message, canRetry: failure.canRetry),
                                           title: failure.target.title,
                                           onOpen: { onOpen(failure.target.kind) },
                                           onCancel: { session.discard(failure.id) },
                                           onSend: { session.retry(failure.id) })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private static func hasRows(_ session: VoiceNoteSession) -> Bool {
        session.showsIndicator || session.sendingTarget != nil || !session.failures.isEmpty
    }
}
