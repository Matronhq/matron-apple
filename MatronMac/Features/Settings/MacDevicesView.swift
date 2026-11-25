import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels

/// Settings → Devices: the signed-in user's device roster (clients and
/// agents) with per-device revoke and the "Add Agent…" pairing entry
/// point. Pull-based per the server spec — refreshed on appear and after
/// every mutation (revoke / pairing-sheet dismiss); roster changes are not
/// journal events. The one live part is an agent box's defaults for new
/// sessions (`box_defaults`), shown on its row and edited in
/// `MacBoxDefaultsSheet`.
struct MacDevicesView: View {
    @State private var viewModel: DevicesViewModel
    @State private var confirming: DeviceDTO?
    /// The device whose rename alert is open, and the draft in its field.
    /// Two pieces of state, not one: `.alert`'s TextField needs a binding
    /// that survives the alert's own re-evaluations.
    @State private var renaming: DeviceDTO?
    @State private var draftName = ""
    /// The agent box whose tag-character alert is open, and its draft —
    /// same two-piece pattern as `renaming`.
    @State private var letterEditing: DeviceDTO?
    @State private var draftLetter = ""
    @State private var showingAddAgent = false
    @State private var showingLink = false
    /// The agent box whose New sessions sheet is open.
    @State private var defaultsEditing: DeviceDTO?
    private let api: any DevicesProviding
    /// Show-QR device linking, opened as a sheet by "Link a Device…". Nil
    /// (tests) hides the button.
    private let deviceLink: (api: any DeviceLinking, serverURL: URL)?

    init(api: any DevicesProviding,
         boxDefaultsUpdates: (@Sendable () -> AsyncStream<BoxDefaultsUpdate>)? = nil,
         deviceLink: (api: any DeviceLinking, serverURL: URL)? = nil,
         onSelfRevoked: @escaping () -> Void) {
        self.api = api
        self.deviceLink = deviceLink
        _viewModel = State(initialValue: DevicesViewModel(api: api, boxDefaultsUpdates: boxDefaultsUpdates,
                                                          onSelfRevoked: onSelfRevoked))
    }

    var body: some View {
        VStack(spacing: 0) {
            List(viewModel.devices) { device in
                DeviceRow(device: device,
                          newSessions: viewModel.showsBoxDefaults(for: device) ? device.defaults?.summary : nil,
                          onEditDefaults: { defaultsEditing = device },
                          onRevoke: { confirming = device },
                          onRename: { draftName = device.name; renaming = device },
                          onSetLetter: {
                              draftLetter = device.tagChar ?? ""
                              letterEditing = device
                          },
                          onToggleProtected: {
                              Task { await viewModel.setProtected(device, on: !device.isProtected) }
                          })
            }
            .overlay {
                // Only claim "no devices" when the load actually succeeded —
                // a failed fetch keeps the roster empty too, and its error
                // is already shown in the footer bar.
                if viewModel.devices.isEmpty && !viewModel.isLoading && viewModel.errorMessage == nil {
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
                if deviceLink != nil {
                    Button("Link a Device…") { showingLink = true }
                }
                Button("Add Agent…") { showingAddAgent = true }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: MacSettingsLayout.paneWidth, height: 400)
        .task { await viewModel.refresh() }
        .task { await viewModel.listenForBoxDefaults() }
        .sheet(item: $defaultsEditing) { device in
            MacBoxDefaultsSheet(deviceID: device.id, viewModel: viewModel)
        }
        // A newly linked device shows up in the roster once the sheet closes.
        .sheet(isPresented: $showingLink, onDismiss: { Task { await viewModel.refresh() } }) {
            if let deviceLink {
                MacDeviceLinkSheet(api: deviceLink.api, serverURL: deviceLink.serverURL)
            }
        }
        .sheet(isPresented: $showingAddAgent, onDismiss: { Task { await viewModel.refresh() } }) {
            MacAddAgentSheet(api: api, existingNames: viewModel.devices.map(\.name),
                             existingTags: viewModel.devices.compactMap(\.tagChar))
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
        .alert("Rename device", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let device = renaming {
                    Task { await viewModel.rename(device, to: draftName) }
                }
                renaming = nil
            }
        } message: {
            Text("This name labels the box everywhere — in Devices and on the chip beside each conversation.")
        }
        .alert("Tag character", isPresented: Binding(
            get: { letterEditing != nil },
            set: { if !$0 { letterEditing = nil } }
        )) {
            TextField("Automatic", text: $draftLetter)
            Button("Cancel", role: .cancel) { letterEditing = nil }
            Button("Save") {
                if let device = letterEditing {
                    // A blank draft clears back to automatic — the view
                    // model maps empty to nil for the server.
                    Task { await viewModel.setTag(device, toDraft: draftLetter) }
                }
                letterEditing = nil
            }
        } message: {
            Text("One character shown before chat titles to identify this machine, on all your devices. Leave empty to derive it from the box name.")
        }
    }
}

struct DeviceRow: View {
    let device: DeviceDTO
    /// The box's defaults for new sessions in one line, or nil when it has
    /// none to edit (a client, or a journal predating them).
    let newSessions: String?
    let onEditDefaults: () -> Void
    let onRevoke: () -> Void
    let onRename: () -> Void
    /// Opens the tag-character editor — agent boxes only; the tag fronts
    /// chat titles and clients have no box letter.
    let onSetLetter: () -> Void
    /// Protects the box, or stops protecting it; agent boxes only.
    let onToggleProtected: () -> Void

    /// Mirrors the iOS row's detail line: an agent box with a tag character
    /// shows it, so the current value is visible without opening the editor.
    private var caption: String {
        var caption = "\(device.kind.capitalized) · Last seen \(device.lastSeenText()) · \(device.lagText)"
        if device.kind == "agent", let letter = device.tagChar {
            caption += " · Tag \(letter)"
        }
        if device.idleExpired { caption += " · Signed out (unused too long)" }
        return caption
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: device.symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            DeviceRowLayout(detailsMinWidth: Self.detailsMinWidth) {
                details
                buttons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    /// The narrowest the details may get before the buttons leave the
    /// right-hand side and wrap under them instead.
    static let detailsMinWidth: CGFloat = 240

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Wraps as a line of chips, so a long name pushes the badges
            // to the next line instead of squeezing them.
            PillFlowLayout(spacing: 6) {
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
                if device.isProtected { ProtectedBoxBadge() }
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let newSessions {
                Text("New sessions: \(newSessions)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The box's limits with when each resets (session and week),
            // from its last report to the journal.
            if device.kind == "agent", let status = device.status {
                AgentCapacityRowContent(capacity: status.capacity, pending: false,
                                        freshness: .report(status, connected: device.connected))
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        if newSessions != nil {
            Button("New Sessions…", action: onEditDefaults)
                .controlSize(.small)
                .help("Choose the agent, model and effort new sessions on this box start with")
        }
        if device.kind == "agent" {
            Button("Tag…", action: onSetLetter)
                .controlSize(.small)
                .help("Choose the character shown before this machine's chat titles")
            Button(device.isProtected ? "Unprotect…" : "Protect…", action: onToggleProtected)
                .controlSize(.small)
                .help("A protected box only takes work you approve yourself, signed with an approval key")
        }
        Button("Rename…", action: onRename)
            .controlSize(.small)
        Button(device.isSelf ? "Sign Out…" : "Revoke…", action: onRevoke)
            .controlSize(.small)
    }
}

/// A device row's body: its details first, then its buttons.
///
/// When there's room, the details take the width their text needs and the
/// buttons fill the rest of the row on the right, as many to a line as fit,
/// each line ending at the row's trailing edge. When the details would get
/// narrower than `detailsMinWidth` that way, the buttons go under the
/// details instead and wrap across the full width. Five buttons on one line
/// beside the details used to crush them into a column a word wide.
struct DeviceRowLayout: Layout {
    let detailsMinWidth: CGFloat
    var columnGap: CGFloat = 16
    var buttonSpacing: CGFloat = 6
    /// Between the details and the buttons when they are stacked.
    var stackedGap: CGFloat = 8

    struct Arrangement {
        var details: CGRect
        var buttons: [CGRect]
        var size: CGSize
        var sideBySide: Bool
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in zip(subviews.indices, [arrangement.details] + arrangement.buttons) {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    func arrange(width: CGFloat?, subviews: Subviews) -> Arrangement {
        guard let detailsView = subviews.first else {
            return Arrangement(details: .zero, buttons: [], size: .zero, sideBySide: false)
        }
        let buttonSizes = subviews.dropFirst().map { $0.sizeThatFits(.unspecified) }
        let widestButton = buttonSizes.map(\.width).max() ?? 0
        let detailsIdeal = detailsView.sizeThatFits(.unspecified).width
        let available = width ?? (detailsIdeal + columnGap + buttonSizes.map(\.width).reduce(0, +)
                                  + buttonSpacing * CGFloat(max(buttonSizes.count - 1, 0)))

        // Side by side: the details get what their text needs, but always
        // leave room for the widest button.
        let detailsWidth = min(detailsIdeal, available - columnGap - widestButton)
        if buttonSizes.isEmpty || detailsWidth >= min(detailsIdeal, detailsMinWidth) {
            let detailsSize = buttonSizes.isEmpty
                ? detailsView.sizeThatFits(ProposedViewSize(width: available, height: nil))
                : detailsView.sizeThatFits(ProposedViewSize(width: detailsWidth, height: nil))
            let columnWidth = available - detailsWidth - columnGap
            let (frames, height) = flow(buttonSizes, width: columnWidth, trailingEdge: available, top: 0)
            return Arrangement(details: CGRect(origin: .zero, size: detailsSize), buttons: frames,
                               size: CGSize(width: available, height: max(detailsSize.height, height)),
                               sideBySide: true)
        }
        let detailsSize = detailsView.sizeThatFits(ProposedViewSize(width: available, height: nil))
        let top = detailsSize.height + stackedGap
        let (frames, height) = flow(buttonSizes, width: available, trailingEdge: nil, top: top)
        return Arrangement(details: CGRect(origin: .zero, size: detailsSize), buttons: frames,
                           size: CGSize(width: available, height: top + height), sideBySide: false)
    }

    /// Lays the buttons out in lines no wider than `width`. With a
    /// `trailingEdge`, each line ends there; without one, lines start at 0.
    private func flow(_ sizes: [CGSize], width: CGFloat, trailingEdge: CGFloat?,
                      top: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var lines: [[Int]] = []
        var lineWidth: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if let last = lines.indices.last, !lines[last].isEmpty,
               lineWidth + buttonSpacing + size.width <= width {
                lines[last].append(index)
                lineWidth += buttonSpacing + size.width
            } else {
                lines.append([index])
                lineWidth = size.width
            }
        }
        var frames = [CGRect](repeating: .zero, count: sizes.count)
        var y = top
        for line in lines {
            let lineHeight = line.map { sizes[$0].height }.max() ?? 0
            let total = line.map { sizes[$0].width }.reduce(0, +) + buttonSpacing * CGFloat(line.count - 1)
            var x = trailingEdge.map { $0 - total } ?? 0
            for index in line {
                frames[index] = CGRect(x: x, y: y, width: sizes[index].width, height: sizes[index].height)
                x += sizes[index].width + buttonSpacing
            }
            y += lineHeight + buttonSpacing
        }
        return (frames, lines.isEmpty ? 0 : y - buttonSpacing - top)
    }
}
