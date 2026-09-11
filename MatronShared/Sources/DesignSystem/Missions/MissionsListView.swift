import SwiftUI
import MatronModels

/// Every mission, open first, closed in a collapsed section (spec: Apps →
/// Missions tab → List). A pure leaf view: hosts map
/// `MissionsListViewModel` into `Model`, so this is snapshot-testable
/// without a view model — the same contract `DecisionsListView` uses.
public struct MissionsListView: View {
    public struct Model: Equatable {
        public var open: [Mission]
        public var closed: [Mission]
        /// `false` shows the unsupported message; hosts hide the tab too.
        public var isSupported: Bool
        public var isRefreshing: Bool
        public init(open: [Mission], closed: [Mission], isSupported: Bool, isRefreshing: Bool) {
            self.open = open; self.closed = closed; self.isSupported = isSupported; self.isRefreshing = isRefreshing
        }
        public var isEmpty: Bool { open.isEmpty && closed.isEmpty }
    }

    let model: Model
    let onSelect: (String) -> Void
    let onRefresh: () async -> Void
    @State private var showClosed = false

    public init(model: Model, onSelect: @escaping (String) -> Void, onRefresh: @escaping () async -> Void) {
        self.model = model; self.onSelect = onSelect; self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack {
                Text("Missions").font(.headline)
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing") }
                Button { Task { await onRefresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh").accessibilityLabel("Refresh")
            }
            .padding(.horizontal).padding(.vertical, 8)
            #endif
            if !model.isSupported {
                placeholder(ContentUnavailableView("Missions not available", systemImage: "exclamationmark.triangle",
                                                   description: Text("Update the journal server to use missions.")))
            } else if model.isEmpty {
                // The copy must not imply the app can start one: only an
                // agent can, through `mission_start` (spec #74).
                placeholder(ContentUnavailableView("No missions yet", systemImage: "flag.checkered",
                                                   description: Text("An agent starts one with mission_start, then posts milestones as the work goes.")))
            } else {
                List {
                    if !model.open.isEmpty {
                        Section("Open") {
                            ForEach(Array(model.open.enumerated()), id: \.element.id) { index, mission in
                                row(mission, hideTopSeparator: index == 0)
                            }
                        }
                    }
                    if !model.closed.isEmpty {
                        Section(isExpanded: $showClosed) {
                            ForEach(Array(model.closed.enumerated()), id: \.element.id) { index, mission in
                                row(mission, hideTopSeparator: index == 0)
                            }
                        } header: {
                            Text("Closed (\(model.closed.count))")
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .refreshable { await onRefresh() }
                #else
                // `.sidebar`/`.inset` inset or hide separators; `.plain`
                // draws one hairline per row edge-to-edge, like Mail.
                .listStyle(.plain)
                #endif
            }
        }
        #if os(iOS)
        .background(MatronTimelineBackground())
        #endif
    }

    /// `hideTopSeparator` drops the hairline above a section's first row —
    /// it would otherwise double the header's own bottom line. Full-width
    /// separators are a Mac-only affordance; iOS keeps its sidebar style
    /// and default row insets.
    private func row(_ mission: Mission, hideTopSeparator: Bool) -> some View {
        Button { onSelect(mission.id) } label: { MissionRowView(mission: mission) }
            .buttonStyle(.plain)
            // iOS List Buttons inherit the accent tint unless reset.
            .foregroundStyle(Color.primary)
            #if os(macOS)
            .macInboxRow(hideTopSeparator: hideTopSeparator)
            #endif
    }

    /// Same shape as `DecisionsListView.placeholder`: on iOS the empty
    /// states still answer pull-to-refresh, because there is no header
    /// refresh button there.
    @ViewBuilder
    private func placeholder<Content: View>(_ content: Content) -> some View {
        #if os(iOS)
        GeometryReader { geo in
            ScrollView { content.frame(width: geo.size.width, height: geo.size.height) }
                .refreshable { await onRefresh() }
        }
        #else
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
