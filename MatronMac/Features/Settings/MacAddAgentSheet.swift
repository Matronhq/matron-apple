#if os(macOS)
import SwiftUI
import MatronJournal
import MatronViewModels

/// The "Add agent" pairing modal. The headless box ran `pair/start` and is
/// showing an 8-character code; this sheet is the approval side: enter the
/// code → see WHO is asking (requester IP — mandatory anti-phish step) →
/// name it → approve → wait for the box to claim its token.
struct MacAddAgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PairingViewModel

    init(api: any DevicesProviding, existingNames: [String]) {
        _viewModel = State(initialValue: PairingViewModel(api: api, existingNames: existingNames))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Agent")
                .font(.title2.bold())
            switch viewModel.phase {
            case .enterCode, .preview:
                codeAndApprove
            case .waitingForClaim:
                waiting
            case .success(let name):
                success(name)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onDisappear { viewModel.cancelWaiting() }
    }

    @ViewBuilder private var codeAndApprove: some View {
        Text("On the box, start pairing — it prints a code like KTNM-3VQ8. Type it here.")
            .font(.callout)
            .foregroundStyle(.secondary)
        TextField("XXXX-XXXX", text: $viewModel.codeInput)
            .font(.system(.title3, design: .monospaced))
            .textFieldStyle(.roundedBorder)
        if let error = viewModel.errorMessage {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
        }
        if case .preview(let requesterIP) = viewModel.phase {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            TextField("Agent name (e.g. dev-7)", text: $viewModel.agentName)
                .textFieldStyle(.roundedBorder)
            Text(viewModel.duplicateNameWarning ?? "Convention: the box's short hostname. The name can't be changed later.")
                .font(.caption)
                .foregroundStyle(viewModel.duplicateNameWarning == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        }
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            if case .preview = viewModel.phase {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Button("Approve") { Task { await viewModel.approve() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(viewModel.isApproving
                                  || viewModel.agentName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (viewModel.expiresAt.map { $0 <= context.date } ?? false))
                }
            }
        }
    }

    @ViewBuilder private var waiting: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for the agent to connect…")
                Text("This finishes automatically once the box collects its token — usually a few seconds. You can close this; the device list will show it when it lands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let error = viewModel.errorMessage {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
        }
        HStack {
            Spacer()
            Button("Close") {
                viewModel.cancelWaiting()
                dismiss()
            }
        }
    }

    @ViewBuilder private func success(_ name: String) -> some View {
        Label("**\(name)** is connected.", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
#endif
