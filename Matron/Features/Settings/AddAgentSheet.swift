import SwiftUI
import MatronJournal
import MatronViewModels

/// The "Add agent" pairing sheet (iOS). The headless box ran `pair/start`
/// and is showing an 8-character code; this is the approval side: enter
/// the code → see WHO is asking (requester IP — mandatory anti-phish
/// step) → name it → approve → wait for the box to claim its token.
struct AddAgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PairingViewModel

    init(api: any DevicesProviding, existingNames: [String]) {
        _viewModel = State(initialValue: PairingViewModel(api: api, existingNames: existingNames))
    }

    var body: some View {
        NavigationStack {
            Form {
                switch viewModel.phase {
                case .enterCode, .preview:
                    codeAndApprove
                case .waitingForClaim:
                    waiting
                case .success(let name):
                    success(name)
                }
            }
            .navigationTitle("Add Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        viewModel.cancelWaiting()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear { viewModel.cancelWaiting() }
    }

    @ViewBuilder private var codeAndApprove: some View {
        Section {
            TextField("XXXX-XXXX", text: $viewModel.codeInput)
                .font(.system(.title3, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        } header: {
            Text("Pairing code")
        } footer: {
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red)
            } else {
                Text("On the box, start pairing — it prints a code like KTNM-3VQ8.")
            }
        }
        if case .preview(let requesterIP) = viewModel.phase {
            Section {
                Text("A device at **\(requesterIP)** is asking to connect as an agent on your account. Only approve if this is your machine — check the code on its terminal.")
                    .font(.callout)
                if let expiresAt = viewModel.expiresAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = Int(expiresAt.timeIntervalSince(context.date))
                        Text(remaining > 0
                            ? "Code expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))"
                            : "Code expired — get a fresh one from the box.")
                            .font(.caption)
                            .foregroundStyle(remaining > 60 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    }
                }
            }
            Section {
                TextField("Agent name (e.g. dev-7)", text: $viewModel.agentName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Button("Approve") { Task { await viewModel.approve() } }
                        .bold()
                        .disabled(viewModel.agentName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (viewModel.expiresAt.map { $0 <= context.date } ?? false))
                }
            } footer: {
                Text(viewModel.duplicateNameWarning ?? "Convention: the box's short hostname. The name can't be changed later.")
                    .foregroundStyle(viewModel.duplicateNameWarning == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
        }
    }

    @ViewBuilder private var waiting: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text("Waiting for the agent to connect…")
            }
            if let error = viewModel.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        } footer: {
            Text("This finishes automatically once the box collects its token — usually a few seconds. You can close this; the device list will show it when it lands.")
        }
    }

    @ViewBuilder private func success(_ name: String) -> some View {
        Section {
            Label("**\(name)** is connected.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button("Done") { dismiss() }
                .bold()
        }
    }
}
