#if os(macOS)
import SwiftUI
import MatronModels
import MatronDesignSystem
import MatronViewModels

/// Settings → "Link a Device" (Mac). Same state machine as iOS
/// (`DeviceLinkViewModel`); Mac only ever SHOWS codes — scanning is a
/// camera-device job, and the Mac claimant path is the manual code field
/// on the sign-in view.
struct MacDeviceLinkView: View {
    @State private var viewModel: DeviceLinkViewModel

    init(api: any DeviceLinking, serverURL: URL) {
        _viewModel = State(initialValue: DeviceLinkViewModel(api: api, serverURL: serverURL))
    }

    var body: some View {
        VStack(spacing: 16) {
            if let notice = viewModel.noticeMessage {
                Text(notice).font(.callout).foregroundStyle(.orange)
            }
            switch viewModel.phase {
            case .loading:
                ProgressView()
            case .showing(let code):
                if let payload = viewModel.qrPayload {
                    QRCodeView(string: payload)
                        .frame(width: 200, height: 200)
                }
                Text(code)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Text("On your new device, open Matron and choose “Scan QR code” — or type the code under “Have a link code?”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .claimed(let deviceName, let requesterIP):
                Text("**\(deviceName)** at **\(requesterIP)** wants to sign in to your account. Only approve if this is your device.")
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Deny", role: .destructive) { Task { await viewModel.deny() } }
                        .disabled(viewModel.isSubmitting)
                    Button("Approve") { Task { await viewModel.approve() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(viewModel.isSubmitting)
                }
                Text("This signs a computer into **your** account — only approve if it's yours, in front of you.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .approved:
                Label("Approved — finishing sign-in on the other device.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                Label("Denied. No device was signed in.", systemImage: "hand.raised.fill")
                    .foregroundStyle(.secondary)
            case .unsupported:
                Text("Server doesn't support device linking yet.")
                    .foregroundStyle(.secondary)
            case .error(let message):
                Text(message).foregroundStyle(.red)
                Button("Try again") { Task { await viewModel.start() } }
            }
        }
        .padding(24)
        .frame(width: 420, height: 420)
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
    }
}
#endif
