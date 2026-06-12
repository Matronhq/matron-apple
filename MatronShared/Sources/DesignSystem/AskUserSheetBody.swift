import SwiftUI
import MatronEvents

/// The inner content of the ask-user sheet — prompt, one of four input
/// kinds, expiry notice, error line, Send button. Single source of
/// truth for BOTH platforms: the iOS wrapper (`AskUserSheet`) presents
/// it with `.presentationDetents` for a half-sheet, the Mac wrapper
/// (`MacAskUserSheet`) pins a fixed frame — nothing in the body itself
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
                ForEach(options, id: \.id) { opt in
                    Button {
                        selectedChoiceIDs = [opt.id]
                    } label: {
                        HStack {
                            Image(systemName: selectedChoiceIDs.contains(opt.id) ? "circle.inset.filled" : "circle")
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
                HStack {
                    // `.borderedProminent` vs `.bordered` are different
                    // concrete ButtonStyle types, so the selected state
                    // can't be a ternary on the style — branch the
                    // whole Button instead.
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

            Button {
                onSend()
            } label: {
                if isSending { ProgressView() } else { Text("Send") }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isSending || isExpired)
        }
        .padding()
    }

    @ViewBuilder
    private func booleanButton(_ title: String, selectedWhen value: Bool) -> some View {
        if booleanAnswer == value {
            Button(title) { booleanAnswer = value }
                .buttonStyle(.borderedProminent)
                .disabled(isExpired)
        } else {
            Button(title) { booleanAnswer = value }
                .buttonStyle(.bordered)
                .disabled(isExpired)
        }
    }
}
