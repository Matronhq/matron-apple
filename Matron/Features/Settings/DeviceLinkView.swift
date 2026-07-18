import SwiftUI
import MatronModels
import MatronDesignSystem
import MatronViewModels

/// Settings → "Link a Device" (iOS): shows a QR the new device scans, then
/// the approve card once someone claims it. The QR self-refreshes on
/// expiry for as long as the screen is open.
struct DeviceLinkView: View {
    @State private var viewModel: DeviceLinkViewModel

    init(api: any DeviceLinking, serverURL: URL) {
        _viewModel = State(initialValue: DeviceLinkViewModel(api: api, serverURL: serverURL))
    }

    var body: some View {
        Form {
            if let notice = viewModel.noticeMessage {
                Section {
                    Text(notice).font(.callout).foregroundStyle(.orange)
                }
            }
            switch viewModel.phase {
            case .loading:
                Section { ProgressView().frame(maxWidth: .infinity) }
            case .showing(let code):
                showing(code)
            case .claimed(let deviceName, let requesterIP):
                claimed(deviceName: deviceName, requesterIP: requesterIP)
            case .approved:
                Section {
                    Label("Approved — finishing sign-in on the other device.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .denied:
                Section {
                    Label("Denied. No device was signed in.", systemImage: "hand.raised.fill")
                        .foregroundStyle(.secondary)
                }
            case .unsupported:
                Section {
                    Text("Server doesn't support device linking yet.")
                        .foregroundStyle(.secondary)
                }
            case .error(let message):
                Section {
                    Text(message).foregroundStyle(.red)
                    Button("Try again") { Task { await viewModel.start() } }
                }
            }
        }
        .navigationTitle("Link a Device")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    @ViewBuilder private func showing(_ code: String) -> some View {
        Section {
            VStack(spacing: 16) {
                if let payload = viewModel.qrPayload {
                    QRCodeView(string: payload)
                        .frame(width: 220, height: 220)
                }
                // The camera-less fallback: the code as selectable text,
                // typed into "Have a link code?" on the new device.
                Text(code)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } footer: {
            Text("On your new device, open Matron and choose “Scan QR code” — or type the code under “Have a link code?”. Codes refresh automatically.")
        }
    }

    @ViewBuilder private func claimed(deviceName: String, requesterIP: String) -> some View {
        Section {
            Text("**\(deviceName)** at **\(requesterIP)** wants to sign in to your account. Only approve if this is your device.")
                .font(.callout)
        }
        Section {
            Button("Approve") { Task { await viewModel.approve() } }
                .bold()
                .disabled(viewModel.isSubmitting)
            Button("Deny", role: .destructive) { Task { await viewModel.deny() } }
                .disabled(viewModel.isSubmitting)
        } footer: {
            Text("Approving signs that device in with full access to your account.")
        }
    }
}
