import SwiftUI
import MatronModels
import MatronDesignSystem

/// Create-item sheet: kind picker, title, free-text body. Mirrors the Mac
/// pane's create sheet with iOS `Form` chrome. Presented from the chat's
/// tasks page.
struct NewItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ItemKind = .task
    @State private var title: String = ""
    @State private var itemBody: String = ""
    let onCreate: (ItemKind, String, String) -> Void

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(ItemKind.allCases, id: \.self) { k in
                        Label(ItemGlyph.label(k), systemImage: ItemGlyph.symbol(k)).tag(k)
                    }
                }
                Section {
                    TextField("Title", text: $title)
                } header: {
                    Text("Title")
                }
                Section {
                    TextEditor(text: $itemBody)
                        .frame(minHeight: 120)
                } header: {
                    Text("Details")
                }
            }
            .navigationTitle("New item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(kind, title.trimmingCharacters(in: .whitespacesAndNewlines), itemBody)
                        dismiss()
                    }
                    .disabled(!canCreate)
                }
            }
        }
    }
}
