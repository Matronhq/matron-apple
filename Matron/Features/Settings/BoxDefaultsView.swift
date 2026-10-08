import SwiftUI
import MatronJournal
import MatronViewModels

/// Settings → Manage Devices → a box → New sessions: the agent, model and
/// effort a session started on this box gets when nobody names them
/// (journal `PUT /devices/:id/defaults`). Every pick shows at once and goes
/// back if the journal refuses it (`DevicesViewModel.setBoxDefault`); a
/// change from another device lands live.
struct BoxDefaultsView: View {
    let deviceID: Int64
    let viewModel: DevicesViewModel
    /// The Codex model field's text, saved when the field is left (`saveDraft`).
    @State private var draftModel = ""
    @State private var draftProblem: String?
    @FocusState private var modelFocused: Bool

    private var device: DeviceDTO? { viewModel.devices.first { $0.id == deviceID } }

    var body: some View {
        Form {
            if let device, let defaults = device.defaults, viewModel.showsBoxDefaults(for: device) {
                Section {
                    picker(.agent, value: defaults.agent, choices: BoxDefaults.agentChoices, device: device)
                    // A box with no default agent ignores a model and effort,
                    // so they are offered once an agent is chosen.
                    if defaults.agent == "claude" {
                        picker(.model, value: defaults.model, choices: defaults.modelChoices, device: device)
                    } else if defaults.agent == "codex" {
                        codexModelField(device)
                    }
                    if defaults.agent != nil {
                        picker(.effort, value: defaults.effort, choices: defaults.effortChoices, device: device)
                    }
                } header: {
                    Text("New sessions")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(BoxDefaults.helpText)
                        if let error = viewModel.errorMessage {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                }
            } else {
                Text("This journal does not support box defaults yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(device?.name ?? "New sessions")
        .onAppear { draftModel = device?.defaults?.model ?? "" }
        // A save, a refusal or another device's change moves the stored
        // model: the field follows it.
        .onChange(of: device?.defaults?.model) { _, model in
            // Not under the user's fingers: a half-typed id stays put.
            guard !modelFocused else { return }
            draftModel = model ?? ""
            draftProblem = nil
        }
        // A typed id is saved however the field is left — Return, focus
        // moving elsewhere, or the screen closing — not only on Return.
        .onChange(of: modelFocused) { _, focused in
            if !focused { saveDraft() }
        }
        .onDisappear { saveDraft() }
    }

    private func picker(_ key: BoxDefaults.Key, value: String?, choices: [BoxDefaults.Choice],
                        device: DeviceDTO) -> some View {
        Picker(key.title, selection: Binding(
            get: { value },
            set: { picked in Task { await viewModel.setBoxDefault(key, to: picked, for: device) } }
        )) {
            ForEach(choices, id: \.self) { choice in
                Text(choice.label).tag(choice.value)
            }
        }
    }

    /// Codex takes any model id it knows, so it is typed, not picked.
    @ViewBuilder
    private func codexModelField(_ device: DeviceDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(BoxDefaults.Key.model.title) {
                TextField("Codex default", text: $draftModel)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($modelFocused)
                    .onSubmit { saveDraft() }
            }
            Text(draftProblem ?? BoxDefaults.codexModelHelp)
                .font(.caption)
                .foregroundStyle(draftProblem == nil ? Color.secondary : Color.red)
        }
    }

    /// Saves the Codex model field if it holds a valid id that differs from
    /// the stored one. `false` (with the reason under the field) when the
    /// draft is not a model id the journal would take.
    @discardableResult
    private func saveDraft() -> Bool {
        guard let device, let defaults = device.defaults, defaults.agent == "codex" else { return true }
        switch defaults.codexModelSave(draft: draftModel) {
        case .unchanged:
            draftProblem = nil
            return true
        case .save(let model):
            draftProblem = nil
            Task { await viewModel.setBoxDefault(.model, to: model, for: device) }
            return true
        case .invalid:
            draftProblem = "Letters, digits, dots and dashes only, at most 64."
            return false
        }
    }
}
