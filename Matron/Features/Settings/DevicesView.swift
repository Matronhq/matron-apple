import SwiftUI
import MatronJournal
import MatronViewModels

/// Settings → Manage Devices: the signed-in user's device roster (clients
/// and agents) with per-device revoke and the "Add Agent" pairing flow.
/// Pull-based per the server spec — refreshed on appear, on pull, and
/// after every mutation; roster changes are not journal events.
struct DevicesView: View {
    @State private var viewModel: DevicesViewModel
    @State private var confirming: DeviceDTO?
    @State private var showingAddAgent = false
    private let api: any DevicesProviding

    init(api: any DevicesProviding, onSelfRevoked: @escaping () -> Void) {
        self.api = api
        _viewModel = State(initialValue: DevicesViewModel(api: api, onSelfRevoked: onSelfRevoked))
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            Section {
                ForEach(viewModel.devices) { device in
                    row(device)
                }
            } footer: {
                Text("Agents are headless machines running the bridge. Revoking a device signs it out immediately — there's no undo.")
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddAgent = true
                } label: {
                    Label("Add Agent", systemImage: "plus")
                }
            }
        }
        .task { await viewModel.refresh() }
        .refreshable { await viewModel.refresh() }
        .sheet(isPresented: $showingAddAgent, onDismiss: { Task { await viewModel.refresh() } }) {
            AddAgentSheet(api: api, existingNames: viewModel.devices.map(\.name))
        }
        // Revoke confirms are the app's job — no undo server-side, and
        // self-revocation is a logout, so the copy changes for is_self.
        .alert(item: $confirming) { device in
            Alert(
                title: Text(device.isSelf ? "Sign out this device?" : "Revoke “\(device.name)”?"),
                message: Text(device.isSelf
                    ? "This device loses access immediately and you'll be returned to sign-in."
                    : "The device loses access immediately. There's no undo — re-enroll it to restore access."),
                primaryButton: .destructive(Text(device.isSelf ? "Sign Out" : "Revoke")) {
                    Task { await viewModel.revoke(device) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func row(_ device: DeviceDTO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
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
        }
        .swipeActions(edge: .trailing) {
            Button(device.isSelf ? "Sign Out" : "Revoke", role: .destructive) {
                confirming = device
            }
        }
        .contextMenu {
            Button(device.isSelf ? "Sign Out This Device" : "Revoke “\(device.name)”",
                   role: .destructive) {
                confirming = device
            }
        }
    }
}
