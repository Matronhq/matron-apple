import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Reply composer for `ItemDetailView`'s comment thread. Matches the shape
/// of the chat composer on each platform rather than forking its own look:
/// iOS mirrors `ComposerView.inputRow` (material-backed, rounded-16 field;
/// mic when the draft is empty, accent send once it isn't); Mac mirrors
/// `MacComposerView`'s field surface (`Color.matronBubbleBot`, rounded 10,
/// bubble shadow) plus Return-to-send (Shift+Return still inserts a
/// newline). Stays a leaf view — the host owns attachment picking and
/// voice-note recording, this view only forwards the intents.
public struct ItemCommentComposer: View {
    @Binding var draft: String
    let isBusy: Bool
    let onSubmit: () -> Void
    let onAttach: () -> Void
    let onVoiceNote: () -> Void

    public init(draft: Binding<String>, isBusy: Bool, onSubmit: @escaping () -> Void, onAttach: @escaping () -> Void, onVoiceNote: @escaping () -> Void) {
        self._draft = draft; self.isBusy = isBusy; self.onSubmit = onSubmit; self.onAttach = onAttach; self.onVoiceNote = onVoiceNote
    }

    /// The field's padding (all edges). Mirrors `ComposerView.inputPadding`;
    /// named so the single-line accessory height below stays tied to it.
    private static let inputPadding: CGFloat = 8

    /// Every accessory button (paperclip left; mic-or-send right) renders
    /// in this fixed-width container so both sides carry identical
    /// gutters — mirrors `MacComposerView.trailingAccessoryWidth`.
    private static let trailingAccessoryWidth: CGFloat = 28

    /// Rendered height of a one-line field: the body font's line height
    /// plus the field's vertical padding, top and bottom. Mirrors
    /// `ComposerView.singleLineInputHeight` / `MacComposerView`'s own so
    /// the accessory buttons centre against a single-line field the same
    /// way the chat composer's do.
    private static var singleLineInputHeight: CGFloat {
        #if canImport(UIKit) && !os(macOS)
        let body = UIFont.preferredFont(forTextStyle: .body)
        return ceil(body.lineHeight) + inputPadding * 2
        #elseif canImport(AppKit)
        let body = NSFont.preferredFont(forTextStyle: .body)
        return ceil(body.ascender - body.descender + body.leading) + inputPadding * 2
        #else
        return 44
        #endif
    }

    /// Whether `draft` is non-blank enough to submit. A pure function (not
    /// just a computed property) so the trailing mic/send switch and, on
    /// the Mac, the plain-Return send-vs-newline decision share one
    /// definition — and so it's unit-testable without constructing
    /// SwiftUI machinery. Mirrors `ComposerViewModel.canSend`.
    static func canSubmit(_ draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSendable: Bool { Self.canSubmit(draft) }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Button(action: onAttach) {
                Image(systemName: "paperclip")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.trailingAccessoryWidth, height: Self.singleLineInputHeight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Attach")

            field

            // Mic when the field is empty (WhatsApp-style), send once the
            // user has typed — same switch as `ComposerView`/`MacComposerView`.
            if isSendable {
                Button(action: onSubmit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: Self.trailingAccessoryWidth, height: Self.singleLineInputHeight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send reply")
                .keyboardShortcut(.return, modifiers: .command)
            } else {
                Button(action: onVoiceNote) {
                    Image(systemName: "mic")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.trailingAccessoryWidth, height: Self.singleLineInputHeight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record voice note")
            }
        }
        .disabled(isBusy)
        .padding()
    }

    /// The text field itself: the same growing `TextField(axis: .vertical)`
    /// shape on both platforms, with each platform's own composer surface
    /// and (Mac-only) Return-key handling.
    @ViewBuilder
    private var field: some View {
        #if os(macOS)
        TextField("Reply…", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .padding(Self.inputPadding)
            .background(Color.matronBubbleBot)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .matronBubbleShadow, radius: 2, y: 1)
            // Plain Return sends (swallowing the newline it would
            // otherwise insert); Shift+Return is ignored here so the
            // field's own default handling inserts the newline, matching
            // Slack/Discord and `MacComposerView`'s Enter/Shift+Enter
            // split. An empty draft's plain Return also falls through
            // (`canSubmit` is false) rather than being force-swallowed —
            // there's nothing to send, so Return behaves like ordinary
            // newline entry.
            .onKeyPress(keys: [.return]) { press in
                if press.modifiers.contains(.shift) { return .ignored }
                guard Self.canSubmit(draft) else { return .ignored }
                onSubmit()
                return .handled
            }
        #else
        TextField("Reply…", text: $draft, axis: .vertical)
            .lineLimit(1...8)
            .padding(Self.inputPadding)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        #endif
    }
}
