#if os(macOS)
import SwiftUI
import AppKit
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels

/// The Boxes page: every paired box with its state, sessions, usage,
/// defaults and disk, in the New Chat list's column layout.
struct MacBoxesPage: View {
    let deps: AppDependencies
    let session: UserSession
    let onOpenConversation: (String) -> Void

    @State private var viewModel: BoxesViewModel
    @State private var expanded: Set<Int64> = []
    @State private var startingOn: DeviceDTO?

    private static let sessionsWidth: CGFloat = 62
    private static let meterWidth: CGFloat = 170
    private static let defaultsWidth: CGFloat = 170
    private static let diskWidth: CGFloat = 92
    private static let actionsWidth: CGFloat = 92
    /// Narrower than this the defaults column folds under the box's name.
    private static let wideLayoutMinWidth: CGFloat = 1_020

    init(deps: AppDependencies, session: UserSession, onOpenConversation: @escaping (String) -> Void) {
        self.deps = deps
        self.session = session
        self.onOpenConversation = onOpenConversation
        _viewModel = State(initialValue: deps.makeBoxesViewModel(for: session))
    }

    var body: some View {
        let rows = viewModel.rows()
        let summary = viewModel.summary(of: rows)
        let columns = BoxCapacity.limitColumns(across: rows.compactMap(\.capacity))
        GeometryReader { proxy in
            let isWide = proxy.size.width >= Self.wideLayoutMinWidth
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Boxes").font(.title.bold())
                        Text(summary.countsText).font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = viewModel.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                    if rows.isEmpty {
                        if viewModel.hasLoaded {
                            Text("No boxes yet. Pair one in Settings → Devices.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 160)
                        } else {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                        }
                    } else {
                        summaryCards(summary)
                        header(columns: columns, isWide: isWide)
                        Divider()
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                rowView(row, columns: columns, isWide: isWide)
                                Divider()
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .task {
            await viewModel.load()
            await viewModel.watch()
        }
        .sheet(item: $startingOn) { device in
            MacNewChatSheet(deps: deps, session: session,
                            windowSize: NSApp.keyWindow?.contentLayoutRect.size,
                            startOn: device) { convoID in
                startingOn = nil
                onOpenConversation(convoID)
            }
        }
    }

    // MARK: Summary

    @ViewBuilder private func summaryCards(_ summary: BoxesSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let spare = summary.spare {
                card(title: "Most spare per day",
                     value: "\(spare.accountEmail ?? BoxesSummary.namesText(summary.spareBoxNames)) · \(spare.percentPerDay)% a day",
                     color: .green,
                     detail: "\(BoxesSummary.namesText(summary.spareBoxNames)) · \(spare.percentLeft)% left, \(BoxCapacity.resetCaption(spare.resetsAt) ?? "")")
            }
            if !summary.nearLimitNames.isEmpty {
                let count = summary.nearLimitNames.count
                card(title: "Near their limit",
                     value: "\(count) \(count == 1 ? "box" : "boxes") at \(BoxAllowances.nearLimitPercent)% or more",
                     color: .red,
                     detail: BoxesSummary.namesText(summary.nearLimitNames))
            }
            if let lowest = summary.lowestDisk {
                card(title: "Lowest disk",
                     value: "\(lowest.name) · \(BoxDisk.sizeText(lowest.disk.freeBytes)) free",
                     color: .primary,
                     detail: "\(lowest.disk.percentFree)% of \(BoxDisk.sizeText(lowest.disk.totalBytes))")
            }
        }
    }

    private func card(title: String, value: String, color: Color, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).foregroundStyle(color).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Table

    private func header(columns: [LimitColumn], isWide: Bool) -> some View {
        HStack(spacing: 12) {
            Text("Box").frame(maxWidth: .infinity, alignment: .leading)
            Text("Sessions").frame(width: Self.sessionsWidth, alignment: .trailing)
            ForEach(columns) { column in
                Text(column.label).frame(width: Self.meterWidth, alignment: .leading)
            }
            if isWide {
                Text("Default for new sessions").frame(width: Self.defaultsWidth, alignment: .leading)
            }
            Text("Disk free").frame(width: Self.diskWidth, alignment: .leading)
            Color.clear.frame(width: Self.actionsWidth, height: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .accessibilityHidden(true)
    }

    private func rowView(_ row: BoxRow, columns: [LimitColumn], isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                nameCell(row, isWide: isWide)
                sessionsCell(row)
                ForEach(columns) { column in
                    BoxMeterView(line: row.capacity?.limitLines.first { $0.id == column.id },
                                 freshness: row.freshness)
                        .frame(width: Self.meterWidth, alignment: .leading)
                }
                if isWide {
                    Text(row.defaultsText ?? "—")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(width: Self.defaultsWidth, alignment: .leading)
                }
                diskCell(row)
                actionsCell(row)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            if expanded.contains(row.id) {
                sessionList(row)
            }
        }
        .background(Self.highlight(row)?.opacity(0.07))
    }

    private static func highlight(_ row: BoxRow) -> Color? {
        row.isNearLimit ? .red : row.isMostSpare ? .green : nil
    }

    private func nameCell(_ row: BoxRow, isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.device.name.isEmpty ? "Unnamed box" : row.device.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(row.state == .online ? .primary : .secondary)
                    .lineLimit(1)
                if row.isNearLimit {
                    BoxBadge("Near limit", color: .red)
                } else if row.isMostSpare {
                    BoxBadge("Most spare", color: .green)
                }
            }
            HStack(spacing: 4) {
                if let caption = row.wake?.caption {
                    Text(caption)
                } else {
                    BoxStateLabel(state: row.state)
                }
                if let email = row.capacity?.accountEmail {
                    Text("· \(email)").lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !isWide, let defaults = row.defaultsText {
                Text(defaults).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let date = row.readingDate {
                Text("as of \(BoxAllowances.ageText(since: date))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func sessionsCell(_ row: BoxRow) -> some View {
        Group {
            if let live = row.liveCount {
                if row.sessions.isEmpty {
                    Text("\(live)").fontWeight(.medium)
                } else {
                    Button {
                        if !expanded.insert(row.id).inserted { expanded.remove(row.id) }
                    } label: {
                        Text("\(live)").fontWeight(.semibold).foregroundStyle(Color.matronAccent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(live) sessions on \(row.device.name)")
                }
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .font(.body)
        .monospacedDigit()
        .frame(width: Self.sessionsWidth, alignment: .trailing)
    }

    private func diskCell(_ row: BoxRow) -> some View {
        Group {
            if let disk = row.capacity?.disk {
                HStack(spacing: 0) {
                    Text(BoxDisk.sizeText(disk.freeBytes)).fontWeight(.semibold)
                    Text(" of \(BoxDisk.sizeText(disk.totalBytes))").foregroundStyle(.secondary)
                }
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .frame(width: Self.diskWidth, alignment: .leading)
    }

    private func actionsCell(_ row: BoxRow) -> some View {
        HStack(spacing: 8) {
            if row.wake == .waking {
                ProgressView().controlSize(.small).accessibilityLabel("Waking \(row.device.name)")
            } else if row.state == .asleep {
                Button("Wake") { Task { await viewModel.wake(row.device) } }
                    .controlSize(.small)
                    .accessibilityLabel("Wake \(row.device.name)")
            }
            if row.canStartSession {
                Button { startingOn = row.device } label: {
                    Image(systemName: "plus")
                }
                .controlSize(.small)
                .help("Start a session on \(row.device.name)")
                .accessibilityLabel("Start a session on \(row.device.name)")
                .accessibilityIdentifier("boxes.start.\(row.id)")
            }
        }
        .frame(width: Self.actionsWidth, alignment: .trailing)
    }

    private func sessionList(_ row: BoxRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(row.sessions) { session in
                Button { onOpenConversation(session.id) } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(session.isRunning ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text(session.title.isEmpty ? "Untitled session" : session.title)
                            .lineLimit(1)
                            .foregroundStyle(Color.matronAccent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.bottom, 10)
    }
}
#endif
