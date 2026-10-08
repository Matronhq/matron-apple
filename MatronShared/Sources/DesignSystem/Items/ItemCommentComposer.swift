import SwiftUI
import MatronModels
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Reply composer for `ItemDetailView`'s comment thread. Matches the chat
/// composer on each platform rather than forking its own behaviour: a tray
/// of staged attachments above the input (the shared `AttachmentTray`), the
/// paperclip on the left, and the mic beside send on the right, send greyed
/// out until there's something to send — "sendable" counting a staged
/// attachment on its own, as chat does.
/// iOS mirrors `ComposerView.inputRow` (material-backed, rounded-16 field);
/// Mac mirrors `MacComposerView`'s field surface. Stays a leaf view — the
/// host owns the tray's contents, attachment picking and voice-note
/// recording, and may swap the text field itself for the chat composer's
/// (`EnvironmentValues.itemCommentField`) so paste and key handling are the
/// chat composer's own code rather than a copy.
public struct ItemCommentComposer: View {
    @Binding var draft: String
    let attachments: [StagedAttachment]
    let isBusy: Bool
    let onSubmit: () -> Void
    let onAttach: () -> Void
    let onVoiceNote: () -> Void
    let onRemoveAttachment: (UUID) -> Void

    @Environment(\.itemCommentField) private var customField

    public init(draft: Binding<String>, attachments: [StagedAttachment] = [], isBusy: Bool,
                onSubmit: @escaping () -> Void, onAttach: @escaping () -> Void, onVoiceNote: @escaping () -> Void,
                onRemoveAttachment: @escaping (UUID) -> Void = { _ in }) {
        self._draft = draft; self.attachments = attachments; self.isBusy = isBusy; self.onSubmit = onSubmit
        self.onAttach = onAttach; self.onVoiceNote = onVoiceNote; self.onRemoveAttachment = onRemoveAttachment
    }

    /// The input's placeholder, shared with any host-supplied field.
    public static let placeholder = "Reply…"

    /// The field's padding (all edges). Mirrors `ComposerView.inputPadding`;
    /// named so the single-line accessory height below stays tied to it.
    static let inputPadding: CGFloat = 8

    /// Every accessory button (paperclip left; mic and send right) renders
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

    /// Whether there is anything to submit: non-blank text, or at least one
    /// staged attachment. A pure function (not just a computed property) so
    /// the send button's enabled state and plain-Return's send decision share
    /// one definition — and so it's unit-testable without constructing
    /// SwiftUI machinery. Mirrors `ComposerViewModel.canSend`.
    static func canSubmit(_ draft: String, hasAttachments: Bool = false) -> Bool {
        hasAttachments || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSendable: Bool { Self.canSubmit(draft, hasAttachments: !attachments.isEmpty) }

    /// Plain Return's action: send when there is something to send and no
    /// write is in flight, otherwise nothing (the key is still consumed by
    /// the field, as in chat).
    private func submitIfSendable() {
        guard isSendable, !isBusy else { return }
        onSubmit()
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Above the input, so what's about to be sent sits next to the
            // words being written about it — the chat composer's own tray.
            AttachmentTray(attachments: attachments, onRemove: onRemoveAttachment)
            inputRow
        }
        // The rows cap at the thread's reading measure and centre with
        // the column above, so the accessory buttons sit on the text's
        // edges and the field is inset by their gutters — the same
        // relationship at every host width, narrow pane or wide window
        // (Bugbot: capping the row wider than the column
        // left a band of widths where the column was centred but the
        // row still filled the host).
        .frame(maxWidth: ItemTypography.measure)
        .padding()
        .frame(maxWidth: .infinity)
        // Pull the row down to hide the keyboard (iOS; inert on the Mac).
        .dragDownDismissesKeyboard()
    }

    private var inputRow: some View {
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

            // The mic stays beside a draft, as in chat: a
            // voice note takes the typed text and the tray with it, as one
            // comment. Send sits beside it throughout, greyed out until
            // there's something to send, so the field doesn't change width
            // on the first typed character — `ComposerView`/`MacComposerView`.
            Button(action: onVoiceNote) {
                Image(systemName: "mic")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.trailingAccessoryWidth, height: Self.singleLineInputHeight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Record voice note")
            Button(action: onSubmit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(isSendable ? Color.accentColor : Color.secondary)
                    .frame(width: Self.trailingAccessoryWidth, height: Self.singleLineInputHeight)
            }
            .buttonStyle(.plain)
            .disabled(!isSendable)
            .accessibilityLabel("Send reply")
            // Only while there's something to send: a shortcut on a
            // disabled button can still claim the key.
            .keyboardShortcut(isSendable ? KeyboardShortcut(.return, modifiers: .command) : nil)
        }
        .disabled(isBusy)
    }

    /// The text field: the host's (`itemCommentField`) when it installed
    /// one, else the standard growing field.
    @ViewBuilder
    private var field: some View {
        let configuration = ItemCommentFieldConfiguration(draft: $draft, placeholder: Self.placeholder,
                                                          submit: submitIfSendable)
        if let customField {
            customField.make(configuration)
        } else {
            ItemCommentTextField(configuration: configuration)
        }
    }
}

/// What a reply field needs from `ItemCommentComposer`: the draft, the
/// placeholder, and plain Return's send action (which already knows whether
/// there is anything to send).
public struct ItemCommentFieldConfiguration {
    public let draft: Binding<String>
    public let placeholder: String
    public let submit: () -> Void

    public init(draft: Binding<String>, placeholder: String, submit: @escaping () -> Void) {
        self.draft = draft; self.placeholder = placeholder; self.submit = submit
    }
}

/// Builds the text field `ItemCommentComposer` shows. Installed by the app
/// hosts (`EnvironmentValues.itemCommentField`) so the tracker's reply field
/// is the chat composer's own: on the Mac its `NSTextView` editor
/// (Shift+Return newline, ⌘V of images and files into the tray), on iOS the
/// standard field with the chat composer's paste support attached.
public struct ItemCommentFieldFactory {
    let make: @MainActor (ItemCommentFieldConfiguration) -> AnyView

    public init(_ make: @escaping @MainActor (ItemCommentFieldConfiguration) -> AnyView) {
        self.make = make
    }
}

extension EnvironmentValues {
    /// The host-supplied reply field, or `nil` for `ItemCommentTextField`'s
    /// standard one (previews, snapshot tests).
    @Entry public var itemCommentField: ItemCommentFieldFactory? = nil
}

/// The standard reply field: the same growing `TextField(axis: .vertical)`
/// shape on both platforms, on each platform's own composer surface. iOS
/// uses it as-is (with the chat composer's paste support behind it — see
/// `ItemDetailHost`); the Mac app replaces it with the chat composer's
/// `NSTextView` editor, so on the Mac this renders only where no host
/// installed one (previews, snapshot tests).
public struct ItemCommentTextField: View {
    let configuration: ItemCommentFieldConfiguration

    public init(configuration: ItemCommentFieldConfiguration) {
        self.configuration = configuration
    }

    public var body: some View {
        #if os(macOS)
        TextField(configuration.placeholder, text: configuration.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .padding(ItemCommentComposer.inputPadding)
            .background(Color.matronBubbleBot)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .matronBubbleShadow, radius: 2, y: 1)
            .onKeyPress(keys: [.return]) { press in
                if press.modifiers.contains(.shift) { return .ignored }
                configuration.submit()
                return .handled
            }
        #else
        TextField(configuration.placeholder, text: configuration.draft, axis: .vertical)
            .lineLimit(1...8)
            .padding(ItemCommentComposer.inputPadding)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        #endif
    }
}
