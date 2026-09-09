import SwiftUI

/// Reply composer for `ItemDetailView`'s comment thread. Mirrors the shape of
/// a chat composer (attach, text, mic/send) but stays a leaf view — the host
/// owns attachment picking and voice-note recording, this view only forwards
/// the intents.
public struct ItemCommentComposer: View {
    @Binding var draft: String
    let isBusy: Bool
    let onSubmit: () -> Void
    let onAttach: () -> Void
    let onVoiceNote: () -> Void

    public init(draft: Binding<String>, isBusy: Bool, onSubmit: @escaping () -> Void, onAttach: @escaping () -> Void, onVoiceNote: @escaping () -> Void) {
        self._draft = draft; self.isBusy = isBusy; self.onSubmit = onSubmit; self.onAttach = onAttach; self.onVoiceNote = onVoiceNote
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: onAttach) { Image(systemName: "paperclip") }.buttonStyle(.plain).accessibilityLabel("Attach")
            TextField("Reply…", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: onVoiceNote) { Image(systemName: "mic.fill") }.buttonStyle(.plain).accessibilityLabel("Record voice note")
            } else {
                Button(action: onSubmit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).accessibilityLabel("Send reply").keyboardShortcut(.return, modifiers: .command)
            }
        }
        .disabled(isBusy)
        .padding(10)
        .background(.bar)
    }
}
