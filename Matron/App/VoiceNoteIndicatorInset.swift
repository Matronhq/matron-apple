import SwiftUI
import MatronDesignSystem
import MatronViewModels

/// Puts the app-wide voice-note pill (`VoiceNoteIndicator`) above a tab's
/// content, under every page that tab's stack pushes. The
/// shell applies it to each tab, so the note's controls follow the user from
/// conversation to item to project. Hidden on the composer that owns the
/// note — its own recording bar is right there.
struct VoiceNoteIndicatorInset: ViewModifier {
    let session: VoiceNoteSession
    let onOpen: (VoiceNoteSession.Target.Kind) -> Void

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
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
            .padding(.horizontal, 12)
            .padding(.bottom, hasRows ? 6 : 0)
            .animation(.snappy, value: hasRows)
        }
    }

    private var hasRows: Bool {
        session.showsIndicator || session.sendingTarget != nil || !session.failures.isEmpty
    }
}

extension View {
    func voiceNoteIndicator(_ session: VoiceNoteSession,
                            onOpen: @escaping (VoiceNoteSession.Target.Kind) -> Void) -> some View {
        modifier(VoiceNoteIndicatorInset(session: session, onOpen: onOpen))
    }
}
