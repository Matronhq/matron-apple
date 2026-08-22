#if os(macOS)
import SwiftUI
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels

/// Mac variant of `NewChatSheet` (the Mac and iOS targets each carry their
/// own `AppDependencies`, so the sheet is duplicated per platform): pick an
/// agent (a sleeping box wakes on pick) → pick a folder → the agent starts
/// a session there (agent RPC — spec 2026-07-15-new-chat-flow-design.md).
/// `onCreated`
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

    /// Whether the picker heads a "Sessions" column at all.
    ///
    /// Fleet-wide and driven by what the rows can actually render: a legacy
    /// bridge parses to an EMPTY capacity, and a sleeping box's cached count
    /// is dropped on purpose (it runs nothing), so either can leave a heading
    /// over a column of em-dashes. An all-asleep fleet is the normal state
    /// now that the host suspends idle boxes, so this is the common path, not
    /// an edge case. A pending fan-out keeps the column: its "…" placeholders
    /// need somewhere to sit.
    static func showsSessions(_ rows: [(capacity: BoxCapacity?, freshness: AgentCapacityFreshness)],
                              pending: Bool) -> Bool {
        pending || rows.contains {
            AgentCapacityRowContent.shownSessions($0.capacity, freshness: $0.freshness) != nil
        }
    }

    /// 70% of the window's width (480…880); lists get 60% of its height
    /// (300…650). nil (previews/tests/no window) → the pre-adaptive sizes.
    static func layout(for windowSize: CGSize?) -> Layout {
        guard let windowSize else { return Layout(width: 480, listMaxHeight: 360) }
        return Layout(
            width: min(max(windowSize.width * 0.7, 480), 880),
            listMaxHeight: min(max(windowSize.height * 0.6, 300), 650))
    }

    /// `@State`, not a plain `let`: the `.sheet` content builder re-runs on
    /// every parent re-render while the sheet is open, and by then the key
    /// window is the sheet itself — a stored property would be rebuilt from
    /// the sheet's own size and collapse toward the 480×300 floors. State
    /// keeps the value captured when the sheet first appeared.
    @State private var layout: Layout

    init(deps: AppDependencies, session: UserSession, windowSize: CGSize? = nil,
         onCreated: @escaping (String) -> Void) {
        self.deps = deps
        self.session = session
        self.onCreated = onCreated
        _layout = State(initialValue: Self.layout(for: windowSize))
        _viewModel = State(initialValue: NewChatViewModel(
            api: deps.agentRPCService(for: session),
            capacityCache: deps.boxCapacityCache(for: session)))
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
        // anything that removes the sheet counts as abandoning the flow —
        // including the wake loops, which would otherwise keep re-asking a
        // box (and a retried start could silently spawn a session) for two
        // minutes.
        // Unconditional: `navigated` is set the moment `.done` lands, before
        // `prepareConversation` returns, so gating on it would leave a sheet
        // dismissed mid-await with the pending task still free to call
        // `onCreated` and yank the user into a chat they walked away from.
        // On the normal path this fires only after `onCreated` has already
        // run, where setting it is a no-op.
        .onDisappear {
            cancelled = true
            viewModel.abandon()
        }
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
            // Offline boxes are seeded from the capacity cache, so their
            // cached lines join the union too — otherwise a fleet whose only
            // reporting box is asleep would show a grid with no columns.
            let columns = BoxCapacity.limitColumns(
                across: agents.compactMap { viewModel.capacities[$0.id] })
            // Grid chrome follows what the rows can actually render, not what
            // the capacities happen to contain. Two ways those differ: a
            // legacy bridge parses to an EMPTY capacity, and a sleeping box's
            // cached session count is dropped — so an all-asleep fleet (the
            // normal state, since the host suspends idle boxes) would
            // otherwise head a "Sessions" column of nothing but em-dashes.
            let showsSessions = Self.showsSessions(
                agents.map { (viewModel.capacities[$0.id], viewModel.capacityFreshness(for: $0.id)) },
                pending: !viewModel.capacityPending.isEmpty)
            let showGrid = showsSessions || !columns.isEmpty
            if showGrid {
                MacAgentPickerHeader(columns: columns, showsSessions: showsSessions)
            }
            List(agents) { agent in
                Button {
                    Task { await viewModel.select(agent: agent) }
                } label: {
                    MacAgentPickerRow(
                        agent: agent,
                        capacity: viewModel.capacities[agent.id],
                        pending: viewModel.capacityPending.contains(agent.id),
                        columns: columns,
                        showsCells: showGrid,
                        showsSessions: showsSessions,
                        freshness: viewModel.capacityFreshness(for: agent.id))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
            // Capacity makes the rows variable-height: grow with them up to
            // the window-derived cap, then scroll.
            .frame(minHeight: 200, maxHeight: layout.listMaxHeight)
            if !agents.contains(where: \.connected) {
                Text("All boxes are asleep — pick one to wake it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func folderPicker(_ agent: DeviceDTO) -> some View {
        Text("Folder on \(agent.name)")
            .font(.callout)
            .foregroundStyle(.secondary)
        if viewModel.isWakingBox {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waking \(agent.name)…")
                if let since = viewModel.wakeStartedAt {
                    Text(since, style: .relative)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.callout)
        }
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
            if viewModel.folders.isEmpty && viewModel.foldersError == nil
                && !viewModel.isWakingBox && !viewModel.wakeGaveUp {
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
            HStack(spacing: 8) {
                Text(error).font(.callout).foregroundStyle(.red)
                // Gated on the same condition retryWake() guards on — a
                // button that renders while a loop still runs would be dead.
                if viewModel.wakeGaveUp && !viewModel.isStarting && !viewModel.isWakingBox {
                    Button("Try Again") {
                        Task { await viewModel.retryWake() }
                    }
                }
            }
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
    /// False for an all-legacy fleet: no data cells at all, so the row
    /// looks exactly like the pre-grid picker instead of a wall of dashes.
    let showsCells: Bool
    /// False when no row in the fleet can render a session count — an
    /// all-asleep fleet drops the column rather than heading a wall of
    /// em-dashes. Fleet-wide, so every row agrees with the header.
    let showsSessions: Bool
    /// Live numbers, or last-known ones for a box the host has put to sleep.
    /// Deliberately NOT defaulted: a `.live` default silently renders cached
    /// numbers as current, which is the one thing this type exists to stop.
    let freshness: AgentCapacityFreshness
    /// Frozen clock for the reset and age captions; nil = now.
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
                     : "Asleep · Last seen \(agent.lastSeenText()) — click to wake")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The data cells are numbers only, so the age of a sleeping
                // box's numbers is captioned here, once per row — but only
                // when the row actually discloses something cached. A legacy
                // bridge persists an EMPTY capacity, and a bare disclaimer
                // under a row showing nothing disclaims thin air.
                if AgentCapacityRowContent.hasCachedContent(capacity, freshness: freshness),
                   let age = freshness.ageText(now: fixedNow ?? Date()) {
                    Text(age)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsCells {
                if showsSessions {
                    sessionsCell
                }
                ForEach(columns) { column in
                    limitCell(column)
                }
            }
            // Asleep rows are pickable too (the journal wakes the box on
            // the first ask), so every row carries the chevron.
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: Self.chevronGutter)
        }
    }

    /// "…" while the fan-out is in flight on a connected box; "—" for
    /// offline boxes and old bridges that sent no capacity blocks.
    private var placeholderText: String {
        pending && agent.connected ? "…" : "—"
    }

    /// Cached blocks show no count at all — a sleeping box runs nothing, so
    /// its last count would be false rather than merely old.
    private var shownSessions: Int? {
        AgentCapacityRowContent.shownSessions(capacity, freshness: freshness)
    }

    private var sessionsCell: some View {
        Group {
            if let live = shownSessions {
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
        guard let live = shownSessions else { return "Sessions unknown" }
        switch live {
        case ...0: return "No active sessions"
        case 1: return "1 active session"
        default: return "\(live) active sessions"
        }
    }

    private func limitCell(_ column: LimitColumn) -> some View {
        let now = fixedNow ?? Date()
        let line = capacity?.limitLines.first { $0.id == column.id }
        let reset = line.flatMap { BoxCapacity.resetText($0.resetsAt, now: now) }
        let expired = line.map { BoxCapacity.hasReset($0.resetsAt, now: now) } ?? false
        return VStack(alignment: .trailing, spacing: 1) {
            if let line {
                Text("\(line.percent)%")
                    .fontWeight(.medium)
                    .monospacedDigit()
                    // Same emphasis rule as the stacked iOS block, from the
                    // same helper: expired lines and cached blocks both lose
                    // the threshold tint.
                    .foregroundStyle(AgentCapacityRowContent
                        .percentEmphasis(line.percent, expired: expired, freshness: freshness)
                        .shapeStyle)
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
            line.map {
                AgentCapacityRowContent.limitAccessibilityLabel(
                    label: column.label, percent: $0.percent, expired: expired,
                    resetText: reset, freshness: freshness)
            } ?? "\(column.label), no data")
    }
}

/// Column captions above the machine list, width-matched to the row cells.
/// Rendered outside the `List` so it never scrolls away.
struct MacAgentPickerHeader: View {
    let columns: [LimitColumn]
    /// Matches the rows: no "Sessions" heading when no row can fill it.
    let showsSessions: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Text("Machine")
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsSessions {
                Text("Sessions")
                    .frame(width: MacAgentPickerRow.sessionsCellWidth, alignment: .trailing)
            }
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
