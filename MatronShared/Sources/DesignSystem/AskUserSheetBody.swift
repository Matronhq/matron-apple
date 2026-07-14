import SwiftUI
import MatronEvents

/// The inner content of an ask-user prompt — prompt text, one of four
/// input kinds, expiry notice, error line. Single-choice options and
/// Yes/No are one-tap answer buttons (web/desktop-client parity); a
/// Send button appears only for the kinds a tap can't fully answer
/// (free text, multi-select, "Other…"). Single source of truth for
/// BOTH platforms via `AskUserCard` — nothing in the body itself
/// branches per platform.
///
/// Parameterised on plain state values + bindings (not the ViewModel)
/// so DesignSystem stays decoupled from app/service types and the
/// snapshot tests can render every input kind directly.
public struct AskUserSheetBody: View {
    public let event: AskUserEvent
    @Binding public var textInput: String
    @Binding public var selectedChoiceIDs: Set<String>
    @Binding public var booleanAnswer: Bool?
    public let isSending: Bool
    public let isExpired: Bool
    public let error: String?
    public let onSend: () -> Void

    public init(
        event: AskUserEvent,
        textInput: Binding<String>,
        selectedChoiceIDs: Binding<Set<String>>,
        booleanAnswer: Binding<Bool?>,
        isSending: Bool,
        isExpired: Bool,
        error: String? = nil,
        onSend: @escaping () -> Void
    ) {
        self.event = event
        self._textInput = textInput
        self._selectedChoiceIDs = selectedChoiceIDs
        self._booleanAnswer = booleanAnswer
        self.isSending = isSending
        self.isExpired = isExpired
        self.error = error
        self.onSend = onSend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(event.prompt).font(.body)

            switch event.kind {
            case .text:
                TextField("Your answer…", text: $textInput, axis: .vertical)
                    .lineLimit(3...8)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isExpired)

            case .choice(let options, let allowOther):
                // One tap answers — a bordered button per option, no radio +
                // Send round-trip (parity with the web/desktop clients and
                // the bridge's Matrix buttons). The binding write lands
                // synchronously before `onSend()`, so the ViewModel's send
                // reads the fresh selection.
                ForEach(options, id: \.id) { opt in
                    Button {
                        selectedChoiceIDs = [opt.id]
                        onSend()
                    } label: {
                        Text(opt.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSending || isExpired)
                }
                if allowOther {
                    TextField("Other…", text: $textInput)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isExpired)
                }

            case .multiChoice(let options, let allowOther):
                ForEach(options, id: \.id) { opt in
                    Button {
                        if selectedChoiceIDs.contains(opt.id) {
                            selectedChoiceIDs.remove(opt.id)
                        } else {
                            selectedChoiceIDs.insert(opt.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: selectedChoiceIDs.contains(opt.id) ? "checkmark.square.fill" : "square")
                            Text(opt.label)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isExpired)
                }
                if allowOther {
                    TextField("Other…", text: $textInput)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isExpired)
                }

            case .boolean:
                // Same one-tap contract as `.choice`.
                HStack {
                    booleanButton("Yes", selectedWhen: true)
                    booleanButton("No", selectedWhen: false)
                    Spacer()
                }
            }

            if isExpired {
                Label("This question has expired.", systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            // Send exists only where a tap can't be the whole answer:
            // free text, multi-select, or a choice set with an "Other…"
            // field. Instant kinds surface in-flight state as a bare
            // spinner instead (their option buttons are already disabled
            // while sending).
            if needsSendButton {
                Button {
                    onSend()
                } label: {
                    if isSending { ProgressView() } else { Text("Send") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSending || isExpired)
            } else if isSending {
                ProgressView()
            }
        }
        .padding()
    }

    private var needsSendButton: Bool {
        switch event.kind {
        case .text, .multiChoice:
            return true
        case .choice(_, let allowOther):
            return allowOther
        case .boolean:
            return false
        }
    }

    @ViewBuilder
    private func booleanButton(_ title: String, selectedWhen value: Bool) -> some View {
        Button(title) {
            booleanAnswer = value
            onSend()
        }
        .buttonStyle(.bordered)
        .disabled(isSending || isExpired)
    }
}
