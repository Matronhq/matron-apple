#if os(macOS)
import SwiftUI
import MatronJournal
import MatronViewModels

/// Settings → Devices: the signed-in user's device roster (clients and
/// agents) with per-device revoke and the "Add Agent…" pairing entry
/// point. Pull-based per the server spec — refreshed on appear and after
/// every mutation (revoke / pairing-sheet dismiss); roster changes are not
/// journal events, so there is nothing to subscribe to.
struct MacDevicesView: View {
    @State private var viewModel: DevicesViewModel
    @State private var confirming: DeviceDTO?
    @State private var showingAddAgent = false
    private let api: any DevicesProviding

    init(api: any DevicesProviding, onSelfRevoked: @escaping () -> Void) {
        self.api = api
        _viewModel = State(initialValue: DevicesViewModel(api: api, onSelfRevoked: onSelfRevoked))
    }

    var body: some View {
        VStack(spacing: 0) {
            List(viewModel.devices) { device in
                DeviceRow(device: device) { confirming = device }
            }
            .overlay {
                if viewModel.devices.isEmpty && !viewModel.isLoading {
                    Text("No devices — that's odd, this Mac should be here. Try Refresh.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            Divider()
            HStack {
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Refresh") { Task { await viewModel.refresh() } }
                Button("Add Agent…") { showingAddAgent = true }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 400)
        .task { await viewModel.refresh() }
        .sheet(isPresented: $showingAddAgent, onDismiss: { Task { await viewModel.refresh() } }) {
            MacAddAgentSheet(api: api, existingNames: viewModel.devices.map(\.name))
        }
        // Revoke confirms are the app's job — the server asks no questions
        // and there is no undo (re-enrollment is the recovery path).
        // Self-revocation is a logout, so the copy changes accordingly.
        .alert(item: $confirming) { device in
            Alert(
                title: Text(device.isSelf ? "Sign out this device?" : "Revoke “\(device.name)”?"),
                message: Text(device.isSelf
                    ? "This Mac loses access immediately and you'll be returned to sign-in."
                    : "The device loses access immediately. There's no undo — re-enroll it to restore access."),
                primaryButton: .destructive(Text(device.isSelf ? "Sign Out" : "Revoke")) {
                    Task { await viewModel.revoke(device) }
                },
                secondaryButton: .cancel()
            )
        }
    }
}

private struct DeviceRow: View {
    let device: DeviceDTO
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name.isEmpty ? "Unnamed device" : device.name)
                        .fontWeight(.medium)
                    if device.isSelf {
                        Text("This device")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text("\(device.kind.capitalized) · Last seen \(device.lastSeenText()) · \(device.lagText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(device.isSelf ? "Sign Out…" : "Revoke…", action: onRevoke)
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}
#endif
