import SwiftUI
import MatronModels
import MatronDesignSystem
import MatronViewModels
import MatronJournal

/// Settings → "Link a Device" (iOS): shows a QR the new device scans, then
/// the approve card once someone claims it. The QR self-refreshes on
/// expiry for as long as the screen is open. A Scan tab lets this
/// (signed-in) device instead scan a signed-out device's rendezvous QR.
struct DeviceLinkView: View {
    @State private var viewModel: DeviceLinkViewModel

    private enum LinkTab: String, CaseIterable { case show = "Show", scan = "Scan" }
    @State private var linkTab: LinkTab = .show
    @State private var showingScanner = false

    init(api: any DeviceLinking, serverURL: URL, relay: any RelayRendezvousing) {
        _viewModel = State(initialValue: DeviceLinkViewModel(api: api, serverURL: serverURL, relay: relay))
    }

    var body: some View {
        Form {
            if let notice = viewModel.noticeMessage {
                Section {
                    Text(notice).font(.callout).foregroundStyle(.orange)
                }
            }
            // The claimed/approved/denied terminal branches take over the
            // screen exactly as before, regardless of which tab was
            // selected when the status poll flipped.
            if case .claimed(let deviceName, let requesterIP) = viewModel.phase {
                claimed(deviceName: deviceName, requesterIP: requesterIP)
            } else if case .approved = viewModel.phase {
                Section {
                    Label("Approved — finishing sign-in on the other device.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else if case .denied = viewModel.phase {
                Section {
                    Label("Denied. No device was signed in.", systemImage: "hand.raised.fill")
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Link mode", selection: $linkTab) {
                    ForEach(LinkTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch linkTab {
                case .show:
                    showTab
                case .scan:
                    scanTab
                }
            }
        }
        .navigationTitle("Link a Device")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
        // The scanner cover lives inside scanTab, so switching tabs tears
        // it down without flipping the flag back — returning to Scan would
        // then reopen the camera unasked.
        .onChange(of: linkTab) { if linkTab != .scan { showingScanner = false } }
    }

    /// The pre-claim QR/status content: loading, showing the code,
    /// unsupported server, or an error + retry.
    @ViewBuilder private var showTab: some View {
        switch viewModel.phase {
        case .loading:
            Section { ProgressView().frame(maxWidth: .infinity) }
        case .showing(let code):
            showing(code)
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
        default:
            EmptyView() // .claimed/.approved/.denied render outside the tab switch above
        }
    }

    @ViewBuilder private var scanTab: some View {
        VStack(spacing: 12) {
            Text("If your computer is showing a Matron QR code, scan it to sign it in as you.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                showingScanner = true
            } label: {
                Label("Scan the computer's QR code", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
        }
        .fullScreenCover(isPresented: $showingScanner) {
            QRScannerView { payload in
                Task { await viewModel.offerScanned(payload) }
            }
        }
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
            Text("This signs a computer into **your** account — only approve if it's yours, in front of you.")
        }
    }
}
