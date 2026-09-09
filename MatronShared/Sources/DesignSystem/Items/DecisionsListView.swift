import SwiftUI
import MatronModels

/// Every open item awaiting the user, across every conversation, newest
/// first, with its origin conversation (app shell, spec §2). A pure leaf
/// view: the host maps `ItemsPanelViewModel.awaitingYou` into `Model` so
/// this is snapshot-testable without a view model. Rows reuse `ItemRow`
/// with the origin subtitle always on — the same rendering `ItemsListView`
/// uses in its "All" scope.
public struct DecisionsListView: View {
    public struct Row: Equatable, Identifiable {
        public let item: TrackerItem
        public let originTitle: String?
        public var id: String { item.id }
        public init(item: TrackerItem, originTitle: String?) {
            self.item = item; self.originTitle = originTitle
        }
    }

    public struct Model: Equatable {
        public var rows: [Row]
        /// `false` shows the unsupported-journal message; `nil` (not yet
        /// known) and `true` both show the list.
        public var isSupported: Bool?
        public var isRefreshing: Bool
        public init(rows: [Row], isSupported: Bool?, isRefreshing: Bool) {
            self.rows = rows; self.isSupported = isSupported; self.isRefreshing = isRefreshing
        }
    }

    let model: Model
    let onSelect: (String) -> Void
    let onOpenConversation: (String) -> Void
    /// Pull to refresh (iOS) and the header button (Mac) both call this —
    /// the host wires it to `ItemsPanelViewModel.refresh()`.
    let onRefresh: () async -> Void

    public init(model: Model, onSelect: @escaping (String) -> Void,
                onOpenConversation: @escaping (String) -> Void, onRefresh: @escaping () async -> Void) {
        self.model = model; self.onSelect = onSelect; self.onOpenConversation = onOpenConversation; self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // The Mac list column has no pull-to-refresh, so the header
            // carries the refresh button; iOS uses `.refreshable` below.
            HStack {
                Text("Decisions").font(.headline)
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing")
                }
                Button { Task { await onRefresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
            }
            .padding(.horizontal).padding(.vertical, 8)
            #endif
            if model.isSupported == false {
                ContentUnavailableView("Tracker not available", systemImage: "exclamationmark.triangle",
                                       description: Text("Update the journal server to use items."))
            } else if model.rows.isEmpty {
                ContentUnavailableView("Nothing needs you", systemImage: "checkmark.seal",
                                       description: Text("Questions and decisions waiting on you, from every conversation, appear here."))
            } else {
                List {
                    ForEach(model.rows) { row in
                        Button { onSelect(row.item.id) } label: {
                            ItemRow(item: row.item, showsOrigin: row.originTitle ?? "Another chat")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.primary)
                        .contextMenu {
                            Button("Open conversation") { onOpenConversation(row.item.originConvoID) }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                .refreshable { await onRefresh() }
                #else
                .listStyle(.inset)
                #endif
            }
        }
    }
}
