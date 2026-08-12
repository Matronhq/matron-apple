#if os(macOS)
import SwiftUI
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels

/// Mac variant of `NewChatSheet` (the Mac and iOS targets each carry their
/// own `AppDependencies`, so the sheet is duplicated per platform): pick a
/// connected agent → pick a folder → the agent starts a session there
/// (agent RPC — spec 2026-07-15-new-chat-flow-design.md). `onCreated`
/// fires with the new conversation id once a placeholder row exists.
struct MacNewChatSheet: View {
    let deps: AppDependencies
    let session: UserSession
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: NewChatViewModel
    /// Guards double-fire when the `.done` onChange races a re-render.
    @State private var navigated = false
    /// Set on any dismissal (Cancel or Esc). A `start` already in flight
    /// can't be recalled — the session will spawn on the box — but its
    /// late `.done` must not yank the user into a chat they abandoned.
    @State private var cancelled = false

    /// Rigid sheet dimensions — Mac sheets ignore flexible frames, so the
    /// size is computed once from the presenting window and frozen.
    struct Layout: Equatable {
        let width: CGFloat
        let listMaxHeight: CGFloat
    }

    /// 70% of the window's width (480…880); lists get 60% of its height
    /// (300…650). nil (previews/tests/no window) → the pre-adaptive sizes.
    static func layout(for windowSize: CGSize?) -> Layout {
        guard let windowSize else { return Layout(width: 480, listMaxHeight: 360) }
        return Layout(
            width: min(max(windowSize.width * 0.7, 480), 880),
            listMaxHeight: min(max(windowSize.height * 0.6, 300), 650))
    }

    private let layout: Layout

    init(deps: AppDependencies, session: UserSession, windowSize: CGSize? = nil,
         onCreated: @escaping (String) -> Void) {
        self.deps = deps
        self.session = session
        self.onCreated = onCreated
        self.layout = Self.layout(for: windowSize)
        _viewModel = State(initialValue: NewChatViewModel(api: deps.agentRPCService(for: session)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Chat").font(.title2.bold())
            switch viewModel.phase {
            case .loadingAgents:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for your agents…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            case .agents(let agents):
                agentPicker(agents)
            case .folders(let agent):
                folderPicker(agent)
            case .done:
                ProgressView().frame(maxWidth: .infinity, minHeight: 180)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    cancelled = true
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: layout.width)
        .task { await viewModel.load() }
        // Esc / window-close dismissal never touches the Cancel button;
        // anything that removes the sheet counts as abandoning the flow.
        .onDisappear { if !navigated { cancelled = true } }
        .onChange(of: viewModel.phase) { _, phase in
            guard case .done(let convoID) = phase, !navigated, !cancelled else { return }
            navigated = true
            Task {
                await deps.prepareConversation(for: session, id: convoID)
                guard !cancelled else { return }
                onCreated(convoID)
            }
        }
    }

    @ViewBuilder private func agentPicker(_ agents: [DeviceDTO]) -> some View {
        if let error = viewModel.errorMessage {
            Text(error).font(.callout).foregroundStyle(.red)
        }
        if agents.isEmpty {
            Text("No agents yet — pair one in Settings → Devices.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            let columns = BoxCapacity.limitColumns(
                across: agents.compactMap { viewModel.capacities[$0.id] })
            // Header only when there is anything to head — a fleet of old
            // bridges keeps today's plain, headerless picker.
            if !viewModel.capacities.isEmpty || !viewModel.capacityPending.isEmpty {
                MacAgentPickerHeader(columns: columns)
            }
            List(agents) { agent in
                Button {
                    Task { await viewModel.select(agent: agent) }
                } label: {
                    MacAgentPickerRow(
                        agent: agent,
                        capacity: viewModel.capacities[agent.id],
                        pending: viewModel.capacityPending.contains(agent.id),
                        columns: columns)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!agent.connected)
            }
            .listStyle(.inset)
            // Capacity makes the rows variable-height: grow with them up to
            // the window-derived cap, then scroll.
            .frame(minHeight: 200, maxHeight: layout.listMaxHeight)
            if !agents.contains(where: \.connected) {
                Text("No agents connected — is the box awake?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func folderPicker(_ agent: DeviceDTO) -> some View {
        Text("Folder on \(agent.name)")
            .font(.callout)
            .foregroundStyle(.secondary)
        if let foldersError = viewModel.foldersError {
            Text(foldersError).font(.caption).foregroundStyle(.secondary)
        }
        List(viewModel.folders) { folder in
            Button {
                Task { await viewModel.start(workdir: folder.path) }
            } label: {
                HStack {
                    Text(folder.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Text(folder.lastUsedText())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isStarting)
        }
        .listStyle(.inset)
        .frame(minHeight: 160, maxHeight: layout.listMaxHeight)
        .overlay {
            if viewModel.folders.isEmpty && viewModel.foldersError == nil {
                Text("No recent folders on \(agent.name).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        HStack(spacing: 8) {
            TextField("~/path/to/project", text: $viewModel.customPath)
                .font(.callout.monospaced())
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await viewModel.start(workdir: viewModel.customPath) } }
            Button {
                Task { await viewModel.start(workdir: viewModel.customPath) }
            } label: {
                if viewModel.isStarting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Start Here")
                }
            }
            .disabled(viewModel.isStarting
                      || viewModel.customPath.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Toggle("Browser tools", isOn: $viewModel.browserEnabled)
            .toggleStyle(.checkbox)
        Text("Blank starts in the agent's default folder — pick a recent one above, or type a path.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if let error = viewModel.errorMessage {
            Text(error).font(.callout).foregroundStyle(.red)
        }
    }
}

/// One machine row in the New Chat picker: the flexible box cell (icon,
/// name + account email, connection caption) followed by fixed-width data
/// cells — sessions, then one cell per fleet-wide usage column — so every
/// row aligns under `MacAgentPickerHeader`. Split out of the sheet so a
/// snapshot test can pin the real row against fixed state (the sheet
/// itself would fire a live `.task` load).
struct MacAgentPickerRow: View {
    let agent: DeviceDTO
    let capacity: BoxCapacity?
    let pending: Bool
    /// Fleet-wide column set — same array for every row in the list.
    let columns: [LimitColumn]
    /// Frozen clock for the reset captions; nil = now.
    var fixedNow: Date?

    /// Cell width contract shared with `MacAgentPickerHeader`.
    static let sessionsCellWidth: CGFloat = 64
    static let limitCellWidth: CGFloat = 108
    static let chevronGutter: CGFloat = 12

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: agent.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name.isEmpty ? "Unnamed agent" : agent.name)
                        .fontWeight(.medium)
                        .foregroundStyle(agent.connected ? .primary : .secondary)
                    if let email = capacity?.accountEmail {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(agent.connected
                     ? "Connected"
                     : "Offline · Last seen \(agent.lastSeenText())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            sessionsCell
            ForEach(columns) { column in
                limitCell(column)
            }
            Group {
                if agent.connected {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Color.clear
                }
            }
            .frame(width: Self.chevronGutter)
        }
    }

    /// "…" while the fan-out is in flight on a connected box; "—" for
    /// offline boxes and old bridges that sent no capacity blocks.
    private var placeholderText: String {
        pending && agent.connected ? "…" : "—"
    }

    private var sessionsCell: some View {
        Group {
            if let live = capacity?.liveSessions {
                Text("\(live)")
                    .fontWeight(.medium)
                    .monospacedDigit()
            } else {
                Text(placeholderText).foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .frame(width: Self.sessionsCellWidth, alignment: .trailing)
        .accessibilityLabel(sessionsAccessibilityLabel)
    }

    private var sessionsAccessibilityLabel: String {
        guard let live = capacity?.liveSessions else { return "Sessions unknown" }
        switch live {
        case ...0: return "No active sessions"
        case 1: return "1 active session"
        default: return "\(live) active sessions"
        }
    }

    private func limitCell(_ column: LimitColumn) -> some View {
        let line = capacity?.limitLines.first { $0.id == column.id }
        let reset = line.flatMap { BoxCapacity.resetText($0.resetsAt, now: fixedNow ?? Date()) }
        return VStack(alignment: .trailing, spacing: 1) {
            if let line {
                Text("\(line.percent)%")
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(UsageMetersFormat.barColor(percent: line.percent))
                if let reset {
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(placeholderText).foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .frame(width: Self.limitCellWidth, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            line.map { "\(column.label), \($0.percent) percent used" + (reset.map { ", \($0)" } ?? "") }
                ?? "\(column.label), no data")
    }
}

/// Column captions above the machine list, width-matched to the row cells.
/// Rendered outside the `List` so it never scrolls away.
struct MacAgentPickerHeader: View {
    let columns: [LimitColumn]

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Text("Machine")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Sessions")
                .frame(width: MacAgentPickerRow.sessionsCellWidth, alignment: .trailing)
            ForEach(columns) { column in
                Text(column.label)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .frame(width: MacAgentPickerRow.limitCellWidth, alignment: .trailing)
            }
            Color.clear.frame(width: MacAgentPickerRow.chevronGutter, height: 1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .accessibilityHidden(true)
    }
}
#endif
