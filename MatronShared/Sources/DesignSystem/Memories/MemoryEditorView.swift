import SwiftUI
import MatronModels

/// The memory editor — one form for an existing memory (name fixed; type,
/// description and notes editable; delete behind a confirm) and for a new
/// one (name editable). Wording and behaviour from matron-web PR #38's
/// `MemoryDetail`. A pure leaf view: `onSave` validates and writes (it is
/// `MemoriesViewModel.save`), answering `nil` on success or the reason it
/// refused, which the form shows without clearing what was typed.
public struct MemoryEditorView: View {
    public struct Draft: Equatable, Sendable {
        public var name: String
        public var type: MemoryType
        public var description: String
        public var body: String
        public init(name: String = "", type: MemoryType = .feedback, description: String = "", body: String = "") {
            self.name = name; self.type = type; self.description = description; self.body = body
        }
        public init(memory: Memory) {
            self.init(name: memory.name, type: memory.type, description: memory.description, body: memory.body)
        }
    }

    enum NotesMode: Hashable { case edit, preview }

    /// The memory being edited, or `nil` for the new-memory form.
    let memory: Memory?
    let onSave: (Draft) async -> String?
    let onDelete: () async -> String?
    var now: Date?

    @State private var draft: Draft
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var notesMode: NotesMode = .edit

    public init(memory: Memory?, onSave: @escaping (Draft) async -> String?,
                onDelete: @escaping () async -> String?, now: Date? = nil) {
        self.memory = memory; self.onSave = onSave; self.onDelete = onDelete; self.now = now
        _draft = State(initialValue: memory.map(Draft.init(memory:)) ?? Draft())
    }

    var isNew: Bool { memory == nil }

    public var body: some View {
        Form {
            #if os(macOS)
            // No navigation bar in the Mac detail column: the title is the
            // form's own header.
            Section {
                Text(memory?.name ?? "New memory").font(.title2.weight(.semibold))
                if let memory { historyCaption(memory) }
            }
            #else
            if let memory {
                Section { historyCaption(memory) }
            }
            #endif
            if isNew {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("avoid-slow-boxes"))
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                        // The section header names it; a Mac grouped form
                        // would otherwise draw the label beside the field.
                        .labelsHidden()
                        .accessibilityIdentifier("memory.name")
                } header: {
                    Text("Name")
                } footer: {
                    Text("Lowercase letters, digits and dashes. It can't be changed later.")
                }
            }
            Section("Type") {
                Picker("Type", selection: $draft.type) {
                    ForEach(MemoryType.pickerOrder, id: \.self) { type in
                        Text(type.label).tag(type)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("memory.type")
            }
            Section {
                TextField("Description", text: $draft.description,
                          prompt: Text("The rule, in one line — this is what the Coordinator reads"), axis: .vertical)
                    .lineLimit(1...4)
                    .labelsHidden()
                    .accessibilityIdentifier("memory.description")
            } header: {
                Text("Description")
            } footer: {
                Text("\(MemoryRules.normalizedDescription(draft.description).utf16.count)/\(MemoryRules.descriptionMaxLength)")
                    .monospacedDigit()
            }
            Section {
                Picker("Notes", selection: $notesMode) {
                    Text("Edit").tag(NotesMode.edit)
                    Text("Preview").tag(NotesMode.preview)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                notes
            } header: {
                Text("Notes")
            } footer: {
                Text("Why, and how to apply it. Markdown, up to 8 KB.")
            }
            Section {
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("memory.error")
                }
                Button { Task { await save() } } label: {
                    Text(busy ? "Saving…" : "Save").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier("memory.save")
            }
            if memory != nil {
                Section {
                    Button("Delete memory", role: .destructive) { confirmingDelete = true }
                        .accessibilityIdentifier("memory.delete")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
        #if os(iOS)
        .navigationTitle(memory?.name ?? "New memory")
        #endif
        .confirmationDialog("Delete this memory?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Agents stop seeing it at once. This can't be undone.")
        }
    }

    private func historyCaption(_ memory: Memory) -> some View {
        Text("\(memory.type.label) · \(MemoryRowView.historyLine(memory, now: now ?? Date()))")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var notes: some View {
        switch notesMode {
        case .edit:
            ZStack(alignment: .topLeading) {
                if draft.body.isEmpty {
                    Text("Why, and how to apply it (markdown)")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft.body)
                    .font(.body.monospaced())
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .accessibilityIdentifier("memory.notes")
            }
        case .preview:
            if draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No notes").foregroundStyle(.tertiary)
            } else {
                MarkdownText(draft.body, cacheParsed: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        error = await onSave(draft)
        busy = false
    }

    private func delete() async {
        guard !busy else { return }
        busy = true
        error = await onDelete()
        busy = false
    }
}
