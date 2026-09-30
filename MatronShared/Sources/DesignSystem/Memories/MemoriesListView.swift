import SwiftUI
import MatronModels

/// The user's memories, sorted by name, with a "New memory" button (spec
/// 2026-09-27 memories, Apps; wording from matron-web PR #38). A pure leaf
/// view: hosts map `MemoriesViewModel` into `Model` and handle the taps.
public struct MemoriesListView: View {
    public struct Model: Equatable {
        /// `nil` until the first load lands.
        public var memories: [Memory]?
        /// `false` once the journal has 404'd `GET /memories`.
        public var isSupported: Bool
        public var isLoading: Bool
        public var loadError: String?
        public init(memories: [Memory]?, isSupported: Bool, isLoading: Bool, loadError: String? = nil) {
            self.memories = memories; self.isSupported = isSupported; self.isLoading = isLoading
            self.loadError = loadError
        }
    }

    public static let caption = "Standing rules and facts every agent can read. The Coordinator starts each session with this list."
    public static let emptyTitle = "No memories yet"
    public static let emptyHint = "Tell an agent a rule about how you want work done and it saves one here, or add one yourself."

    let model: Model
    /// The selected row's name (Mac sidebar highlight); `nil` on iOS.
    let selectedName: String?
    let onSelect: (String) -> Void
    let onNew: () -> Void
    let onRefresh: () async -> Void
    var now: Date?

    public init(model: Model, selectedName: String? = nil, onSelect: @escaping (String) -> Void,
                onNew: @escaping () -> Void, onRefresh: @escaping () async -> Void, now: Date? = nil) {
        self.model = model; self.selectedName = selectedName; self.onSelect = onSelect; self.onNew = onNew
        self.onRefresh = onRefresh; self.now = now
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack {
                Text("Memories").font(.headline)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Refreshing") }
                Button { Task { await onRefresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh").accessibilityLabel("Refresh")
                if model.isSupported {
                    Button { onNew() } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).help("New memory").accessibilityLabel("New memory")
                        .accessibilityIdentifier("memories.new")
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
            #endif
            content
        }
        #if os(iOS)
        .background(MatronTimelineBackground())
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if !model.isSupported {
            placeholder(ContentUnavailableView("Memories not available", systemImage: "exclamationmark.triangle",
                                               description: Text("This journal doesn't have memories yet. Update the journal server to use them.")))
        } else if let memories = model.memories {
            if memories.isEmpty {
                placeholder(VStack(spacing: 16) {
                    ContentUnavailableView(Self.emptyTitle, systemImage: "brain",
                                           description: Text(Self.emptyHint))
                    #if os(iOS)
                    Button("New memory") { onNew() }.buttonStyle(.borderedProminent)
                    #endif
                })
            } else {
                list(memories)
            }
        } else if let loadError = model.loadError {
            // Nothing loaded yet and the load failed: an empty list would
            // read as a false "No memories yet".
            placeholder(VStack(spacing: 12) {
                ContentUnavailableView("Couldn't load memories", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
                Button("Try again") { Task { await onRefresh() } }
            })
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ memories: [Memory]) -> some View {
        List {
            // The caption and any stale notice are a plain first row, not a
            // section header: the iOS `.sidebar` style would make a header
            // a collapsible disclosure.
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.caption).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // A refresh that failed after a load keeps the list (loads
                // never clear it) but says it may be out of date.
                if let loadError = model.loadError {
                    HStack(spacing: 6) {
                        Text("Couldn't refresh memories, so they may be out of date.")
                        Button("Try again") { Task { await onRefresh() } }
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(loadError)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            #if os(macOS)
            .padding(.horizontal, 4)
            #endif
            ForEach(Array(memories.enumerated()), id: \.element.id) { index, memory in
                row(memory, hideTopSeparator: index == 0)
            }
        }
        #if os(iOS)
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .refreshable { await onRefresh() }
        #else
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        #endif
    }

    private func row(_ memory: Memory, hideTopSeparator: Bool) -> some View {
        Button { onSelect(memory.name) } label: {
            MemoryRowView(memory: memory, now: now)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // iOS List Buttons inherit the accent tint unless reset.
        .foregroundStyle(Color.primary)
        .accessibilityIdentifier("memories.row.\(memory.name)")
        #if os(macOS)
        .listRowBackground(selectedName == memory.name ? Color.accentColor.opacity(0.18) : Color.clear)
        .macInboxRow(hideTopSeparator: hideTopSeparator)
        #endif
    }

    /// Same shape as `MissionsDashboardView.placeholder`: on iOS the empty
    /// states still answer pull-to-refresh.
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

/// One memory row: name and type label, the one-line description, and
/// "Updated 5 minutes ago by an agent".
public struct MemoryRowView: View {
    let memory: Memory
    var now: Date?

    public init(memory: Memory, now: Date? = nil) {
        self.memory = memory; self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(memory.name).font(.body.weight(.medium).monospaced()).lineLimit(1)
                Text(memory.type.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .fixedSize()
            }
            Text(Self.oneLine(memory.description)).font(.subheadline).lineLimit(2)
            Text(Self.updatedLine(memory, now: now ?? Date())).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// "Updated 5 minutes ago by you" — web's row meta line.
    public static func updatedLine(_ memory: Memory, now: Date) -> String {
        "Updated \(relative(memory.updatedAt, now: now)) by \(Memory.authorPhrase(memory.updatedBy))"
    }

    /// "Saved 3 days ago by an agent, updated 5 minutes ago by you" — the
    /// editor's caption.
    public static func historyLine(_ memory: Memory, now: Date) -> String {
        "Saved \(relative(memory.createdAt, now: now)) by \(Memory.authorPhrase(memory.createdBy)), "
            + "updated \(relative(memory.updatedAt, now: now)) by \(Memory.authorPhrase(memory.updatedBy))"
    }

    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
