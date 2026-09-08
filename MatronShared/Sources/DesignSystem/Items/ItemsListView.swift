import SwiftUI
import MatronModels

public struct ItemsListView: View {
    public struct Model: Equatable {
        public var needsYou: [TrackerItem]
        public var tasks: [TrackerItem]
        public var decisions: [TrackerItem]
        public var done: [TrackerItem]
        public var originTitles: [String: String]
        public var isSupported: Bool
        public var isRefreshing: Bool
        public init(needsYou: [TrackerItem], tasks: [TrackerItem], decisions: [TrackerItem], done: [TrackerItem],
                    originTitles: [String: String], isSupported: Bool, isRefreshing: Bool) {
            self.needsYou = needsYou; self.tasks = tasks; self.decisions = decisions; self.done = done
            self.originTitles = originTitles; self.isSupported = isSupported; self.isRefreshing = isRefreshing
        }
        var isEmpty: Bool { needsYou.isEmpty && tasks.isEmpty && decisions.isEmpty && done.isEmpty }
    }

    let model: Model
    @Binding var scope: ItemsScope
    let convoID: String
    let thumbnail: (TrackerItem) -> Image?
    let onSelect: (TrackerItem) -> Void
    let onMove: (String, Int) -> Void
    let onCreate: () -> Void
    let onOpenConversation: (String) -> Void

    public init(model: Model, scope: Binding<ItemsScope>, convoID: String, thumbnail: @escaping (TrackerItem) -> Image?,
                onSelect: @escaping (TrackerItem) -> Void, onMove: @escaping (String, Int) -> Void,
                onCreate: @escaping () -> Void, onOpenConversation: @escaping (String) -> Void) {
        self.model = model; self._scope = scope; self.convoID = convoID; self.thumbnail = thumbnail
        self.onSelect = onSelect; self.onMove = onMove; self.onCreate = onCreate; self.onOpenConversation = onOpenConversation
    }

    private var isAll: Bool { if case .all = scope { return true } else { return false } }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Scope", selection: Binding(get: { isAll ? 1 : 0 }, set: { scope = $0 == 1 ? .all : .convo(convoID) })) {
                    Text("This chat").tag(0)
                    Text("All").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing")
                }
                Button(action: onCreate) { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New item")
                    .help("New item")
            }
            .padding(.horizontal).padding(.vertical, 8)
            if !model.isSupported {
                ContentUnavailableView("Tracker not available", systemImage: "exclamationmark.triangle",
                                       description: Text("Update the journal server to use items."))
            } else if model.isEmpty {
                ContentUnavailableView("Nothing tracked yet", systemImage: "checklist",
                                       description: Text("Questions, tasks and decisions the agent files appear here."))
            } else {
                List {
                    section("Needs you", model.needsYou, movable: false)
                    section("Tasks", model.tasks, movable: true)
                    section("Decisions", model.decisions, movable: false)
                    section("Done", model.done, movable: false)
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [TrackerItem], movable: Bool) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    Button { onSelect(item) } label: {
                        ItemRow(item: item, showsOrigin: isAll ? (model.originTitles[item.originConvoID] ?? "Another chat") : nil,
                                thumbnail: thumbnail(item))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.primary)
                    .contextMenu {
                        if isAll { Button("Open conversation") { onOpenConversation(item.originConvoID) } }
                    }
                }
                .onMove(perform: movable ? { from, to in
                    guard let f = from.first else { return }
                    let id = items[f].id
                    onMove(id, to > f ? to - 1 : to)
                } : nil)
                .moveDisabled(!movable)
            }
        }
    }
}
