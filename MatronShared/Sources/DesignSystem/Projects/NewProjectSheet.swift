import SwiftUI

/// "New project" (spec §6 "Filing"): a title and an optional line on what
/// it is for. Stays open with the error when the create fails.
public struct NewProjectSheet: View {
    let onCreate: (String, String?) async -> String?
    let onCancel: () -> Void
    @State private var title = ""
    @State private var details = ""
    @State private var isCreating = false
    @State private var error: String?

    public init(onCreate: @escaping (String, String?) async -> String?, onCancel: @escaping () -> Void) {
        self.onCreate = onCreate; self.onCancel = onCancel
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New project").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("projects.new.title")
            TextField("What is it for? (optional)", text: $details, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction).disabled(isCreating)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreating || trimmedTitle.isEmpty || trimmedTitle.utf16.count > 200)
            }
        }
        .padding(20)
    }

    private func create() {
        isCreating = true
        error = nil
        Task {
            let failure = await onCreate(trimmedTitle, details)
            isCreating = false
            error = failure
        }
    }
}
