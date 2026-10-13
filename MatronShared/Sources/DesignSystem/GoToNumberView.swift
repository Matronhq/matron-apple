import SwiftUI

/// The "Go to Number" field, shared by the Mac sheet and the iPhone one: a
/// number field focused as it appears, Go as the default button, Cancel,
/// and one line under the field for a number that leads nowhere
/// ("No #412") — in place rather than an alert, so the number can be
/// corrected. A dumb projection over plain values + closures, like
/// `ChatSearchBar`: the state lives in `GoToNumberViewModel`.
public struct GoToNumberView: View {
    @Binding var text: String
    let message: String?
    /// The number is being looked up. The field stays live: editing it
    /// drops the lookup (`GoToNumberViewModel.text`).
    let isBusy: Bool
    let canGo: Bool
    let onGo: () -> Void
    let onCancel: () -> Void

    @FocusState private var fieldFocused: Bool

    public init(text: Binding<String>, message: String?, isBusy: Bool, canGo: Bool,
                onGo: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self._text = text
        self.message = message
        self.isBusy = isBusy
        self.canGo = canGo
        self.onGo = onGo
        self.onCancel = onCancel
    }

    public static let title = "Go to Number"
    static let prompt = "Item, mission, milestone or project number"

    public var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.title).font(.headline)
            field
                .textFieldStyle(.roundedBorder)
            messageLine
            HStack {
                if isBusy { ProgressView().controlSize(.small) }
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
                } footer: {
                    messageLine
                }
            }
            .navigationTitle(Self.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isBusy {
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

    /// The line under the field: why the number went nowhere, else what
    /// the field takes.
    private var messageLine: some View {
        Text(message ?? Self.prompt)
            .font(.caption)
            .foregroundStyle(message == nil ? Color.secondary : Color.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("goto.message")
    }
}
