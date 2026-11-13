import SwiftUI
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels

/// A pushed box's route on the Boxes stack.
enum BoxRoute {
    private static let prefix = "box/"

    static func path(_ id: Int64) -> String { prefix + String(id) }

    static func id(from path: String) -> Int64? {
        guard path.hasPrefix(prefix) else { return nil }
        return Int64(path.dropFirst(prefix.count))
    }
}

/// The Boxes page: a card per paired box. Lives under More.
struct BoxesScreen: View {
    let viewModel: BoxesViewModel
    let deps: AppDependencies
    let session: UserSession
    /// False while another tab is up: the page stays mounted but stops
    /// reading.
    let isActive: Bool
    let onOpenChat: (String) -> Void

    @State private var startingOn: DeviceDTO?

    var body: some View {
        let rows = viewModel.rows()
        let summary = viewModel.summary(of: rows)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !rows.isEmpty {
                    Text(summary.countsText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                if let error = viewModel.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 4)
                }
                if let spare = summary.spare {
                    spareCard(spare, summary: summary)
                }
                if !rows.isEmpty {
                    historyLink
                }
                ForEach(rows) { row in
                    card(row)
                }
                if rows.isEmpty {
                    Group {
                        if viewModel.hasLoaded {
                            Text("No boxes yet. Pair one in Settings → Devices.")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Boxes")
        .refreshable { await viewModel.load() }
        .task(id: isActive) {
            guard isActive else { return }
            await viewModel.load()
            await viewModel.watch()
        }
        .sheet(item: $startingOn) { device in
            NewChatSheet(deps: deps, session: session, startOn: device) { convoID in
                startingOn = nil
                onOpenChat(convoID)
            }
        }
    }

    private var historyLink: some View {
        NavigationLink(value: UsageHistoryScreen.path) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage history").font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                    Text("How much of each week's allowance went unused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("boxes.usageHistory")
    }

    private func spareCard(_ spare: AllowanceSpare, summary: BoxesSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Most spare per day").font(.caption).foregroundStyle(.secondary)
            Text("\(spare.accountEmail ?? BoxesSummary.namesText(summary.spareBoxNames)) · \(spare.percentPerDay)% a day")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .lineLimit(1)
            Text("\(BoxesSummary.namesText(summary.spareBoxNames)) · \(spare.percentLeft)% left, \(BoxCapacity.resetCaption(spare.resetsAt) ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func card(_ row: BoxRow) -> some View {
        let lines = row.capacity?.limitLines ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(row.device.name.isEmpty ? "Unnamed box" : row.device.name)
                    .font(.headline)
                    .foregroundStyle(row.state == .online ? .primary : .secondary)
                    .lineLimit(1)
                if row.isNearLimit {
                    BoxBadge("Near limit", color: .red)
                } else if row.isMostSpare {
                    BoxBadge("Most spare", color: .green)
                }
                Spacer(minLength: 4)
                trailingControls(row)
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
            if !lines.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())],
                          alignment: .leading, spacing: 10) {
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            BoxMeterView(line: line, freshness: row.freshness)
                        }
                    }
                }
            }
            if let footer = footerText(row) {
                Text(footer).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let date = row.readingDate {
                Text("as of \(BoxAllowances.ageText(since: date))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func footerText(_ row: BoxRow) -> String? {
        let disk = row.capacity?.disk.map {
            "\(BoxDisk.sizeText($0.freeBytes)) free of \(BoxDisk.sizeText($0.totalBytes))"
        }
        let parts = [row.defaultsText, disk].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private func trailingControls(_ row: BoxRow) -> some View {
        if let live = row.liveCount {
            if row.sessions.isEmpty {
                Text("\(live) live").font(.subheadline).foregroundStyle(.secondary)
            } else {
                NavigationLink(value: BoxRoute.path(row.id)) {
                    Text("\(live) live ›").font(.subheadline.weight(.semibold)).foregroundStyle(Color.matronAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(live) sessions on \(row.device.name)")
            }
        }
        if row.wake == .waking {
            ProgressView().accessibilityLabel("Waking \(row.device.name)")
        } else if row.state == .asleep {
            Button("Wake") { Task { await viewModel.wake(row.device) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Wake \(row.device.name)")
        }
        if row.canStartSession {
            Button { startingOn = row.device } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Start a session on \(row.device.name)")
            .accessibilityIdentifier("boxes.start.\(row.id)")
        }
    }
}

/// The sessions on one box, pushed from its card.
struct BoxSessionsView: View {
    let row: BoxRow
    let onOpenChat: (String) -> Void

    var body: some View {
        List {
            MatronGroupedRows {
                ForEach(row.sessions) { session in
                    Button { onOpenChat(session.id) } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(session.isRunning ? Color.green : Color.gray)
                                .frame(width: 7, height: 7)
                            Text(session.title.isEmpty ? "Untitled session" : session.title)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            Text(session.isRunning ? "Running" : "Waiting")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
            }
        }
        .navigationTitle(row.device.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
