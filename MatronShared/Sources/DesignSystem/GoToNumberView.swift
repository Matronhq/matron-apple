import SwiftUI

/// The "Go to Number" field, shared by the Mac sheet and the iPhone one: a
/// number field focused as it appears, and under it what the number in it
/// names — a row to open, or a line saying nothing carries that number —
/// shown as it is typed, with Go as the default button and Cancel. A dumb
/// projection over plain values + closures, like `ChatSearchBar`: the
/// state lives in `GoToNumberViewModel`.
public struct GoToNumberView: View {
    /// What is shown under the field.
    public enum Outcome: Equatable {
        /// Nothing typed, or not a number: what the field takes.
        case hint
        case looking
        /// The number names something: its kind and number over its title. `note`
        /// says why it cannot be opened, and the row is then not a button.
        case found(heading: String, title: String?, note: String?)
        /// Nothing carries the number. Not an error.
        case nothing(String)
        case failed(String)
    }

    @Binding var text: String
    let outcome: Outcome
    /// Go was pressed and the target is on its way. The field stays live:
    /// editing the number drops it (`GoToNumberViewModel.text`).
    let isOpening: Bool
    let canGo: Bool
    let onGo: () -> Void
    let onCancel: () -> Void

    @FocusState private var fieldFocused: Bool

    public init(text: Binding<String>, outcome: Outcome, isOpening: Bool, canGo: Bool,
                onGo: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self._text = text
        self.outcome = outcome
        self.isOpening = isOpening
        self.canGo = canGo
        self.onGo = onGo
        self.onCancel = onCancel
    }

    public static let title = "Go to Number"
    static let prompt = "Item, mission, milestone or project number"
    static let looking = "Looking…"

    public var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.title).font(.headline)
            field
                .textFieldStyle(.roundedBorder)
            // Room for the two-line row whatever is said, so the sheet
            // does not change height as the number is typed.
            outcomeView
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            HStack {
                if isOpening { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Go", action: onGo)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canGo)
                    .accessibilityIdentifier("goto.go")
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { fieldFocused = true }
        #else
        NavigationStack {
            Form {
                Section {
                    field
                        // Digits only: the `#` is optional and Go is in the bar.
                        .keyboardType(.numberPad)
                    if case .found = outcome { outcomeView }
                } footer: {
                    if case .found = outcome { EmptyView() } else { outcomeView }
                }
            }
            .navigationTitle(Self.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isOpening {
                        ProgressView()
                    } else {
                        Button("Go", action: onGo)
                            .disabled(!canGo)
                            .accessibilityIdentifier("goto.go")
                    }
                }
            }
        }
        .onAppear { fieldFocused = true }
        #endif
    }

    private var field: some View {
        TextField("#", text: $text, prompt: Text("#412"))
            .focused($fieldFocused)
            .onSubmit { if canGo { onGo() } }
            .accessibilityLabel(Self.prompt)
            .accessibilityIdentifier("goto.field")
    }

    @ViewBuilder
    private var outcomeView: some View {
        switch outcome {
        case .hint:
            line(Self.prompt, style: Color.secondary)
        case .looking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                line(Self.looking, style: Color.secondary)
            }
        case .found(let heading, let title, let note):
            if let note {
                foundRow(heading: heading, title: title, note: note)
            } else {
                Button(action: onGo) {
                    foundRow(heading: heading, title: title, note: nil)
                }
                .buttonStyle(.plain)
                .disabled(!canGo)
                .accessibilityIdentifier("goto.result")
            }
        case .nothing(let message):
            line(message, style: Color.secondary)
        case .failed(let message):
            line(message, style: Color.red)
        }
    }

    /// One line under the field.
    private func line(_ message: String, style: Color) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(style)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("goto.message")
    }

    /// What the number names: the kind and number, then its title — or,
    /// for one that cannot be opened, why not.
    private func foundRow(heading: String, title: String?, note: String?) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).font(.body.weight(.medium))
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if note == nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        #if os(macOS)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        #endif
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
