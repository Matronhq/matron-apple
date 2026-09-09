import SwiftUI
import MatronModels
import MatronJournal
import MatronViewModels
import MatronDesignSystem

/// iOS right-edge drawer for the tracker panel (spec: Apps → Panel
/// content). A dimming scrim + sliding panel over the whole chat screen,
/// hosting a `NavigationStack` whose root is `ItemsListView` and whose
/// push destination is `ItemDetailHost`. Opened by the toolbar `checklist`
/// button or a right-edge swipe on the chat container (see `ChatView`);
/// the `ItemsPanelViewModel` is owned and started by `ChatView` so the
/// toolbar's `NeedsYouBadge` stays live while the drawer is closed — this
/// view only presents it.
struct ItemsDrawer: View {
    @Binding var isPresented: Bool
    /// PR B / Task 13: hoisted out of a private `@State` so `ChatView` can
    /// push an item straight from a tapped inline `.itemMarker` timeline
    /// card without going through this drawer's own `onSelect`. Owned by
    /// `ChatView` (survives the drawer's own view identity the same way
    /// `isPresented` already does), reset to `[]` the same places it
    /// always was — `close()`'s deferred clear, below.
    @Binding var path: [String]
    let viewModel: ItemsPanelViewModel
    let session: UserSession
    let onOpenConversation: (String) -> Void

    @Environment(\.appDependencies) private var deps
    @State private var showCreate = false
    @State private var originTitles: [String: String] = [:]
    /// Live drag offset while the close-gesture is tracking; snaps back to
    /// 0 on a drag that didn't clear the close threshold.
    @State private var dragX: CGFloat = 0
    /// Bumped by every `close()` and by every reopen (`isPresented` going
    /// true) — the deferred `path = []` task `close()` schedules captures
    /// this and only clears `path` if it's still the current generation
    /// (Bugbot: a bare 250ms timer with no token would clear a fresh
    /// re-push if the drawer closed and reopened within that window).
    @State private var closeGeneration = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                if isPresented {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)
                        .accessibilityLabel("Close tasks and decisions")
                        .accessibilityAddTraits(.isButton)
                    panel
                        .frame(width: min(geo.size.width * 0.88, 420))
                        .frame(maxHeight: .infinity)
                        .offset(x: max(dragX, 0))
                        // `simultaneousGesture`, not `gesture`: an exclusive
                        // gesture here wins the very first touch anywhere on
                        // the panel and starves the list/detail's own
                        // scrolling and a pushed detail's back-swipe. The
                        // leading-32pt-start + horizontal-dominant guard
                        // below is what actually keeps it from firing on a
                        // vertical scroll or a mid-panel horizontal swipe —
                        // `simultaneous` alone isn't enough, since `onEnded`
                        // still runs for every recognized drag.
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 10)
                                // Only at the list root: on a pushed detail the same
                                // leading strip belongs to the system back-swipe, and
                                // both recognising one touch would pop AND close.
                                .onChanged { v in
                                    guard path.isEmpty, v.startLocation.x < 32, abs(v.translation.width) > abs(v.translation.height) else { return }
                                    dragX = max(v.translation.width, 0)
                                }
                                .onEnded { v in
                                    guard path.isEmpty, v.startLocation.x < 32, abs(v.translation.width) > abs(v.translation.height) else {
                                        withAnimation(.easeOut(duration: 0.18)) { dragX = 0 }
                                        return
                                    }
                                    if v.translation.width > 60 {
                                        close()
                                    } else {
                                        withAnimation(.easeOut(duration: 0.18)) { dragX = 0 }
                                    }
                                }
                        )
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: isPresented)
        }
        // No hit-testing (and no layout cost beyond a GeometryReader) while
        // closed — this overlay sits over the entire chat screen.
        .allowsHitTesting(isPresented)
        // A reopen invalidates any close still winding down its deferred
        // `path` clear — see `closeGeneration`.
        .onChange(of: isPresented) { _, newValue in
            if newValue { closeGeneration += 1 }
        }
    }

    private func close() {
        withAnimation { isPresented = false }
        dragX = 0
        closeGeneration += 1
        let generation = closeGeneration
        // Deferred, not synchronous: clearing `path` immediately pops the
        // pushed detail back to the list mid-slide-out, so the close
        // animation visibly flashes the list for a frame before it's gone.
        // Matches the panel's own 0.22s `.animation(.easeInOut)`. Guarded
        // by generation + `!isPresented`: a close-then-reopen within the
        // 250ms window must not wipe the fresh reopen's `path`.
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard generation == closeGeneration, !isPresented else { return }
            path = []
        }
    }

    private var panel: some View {
        NavigationStack(path: $path) {
            ItemsListView(
                model: .init(
                    needsYou: viewModel.sections.needsYou,
                    tasks: viewModel.sections.tasks,
                    decisions: viewModel.sections.decisions,
                    done: viewModel.sections.done,
                    originTitles: originTitles,
                    isSupported: viewModel.isSupported,
                    isRefreshing: viewModel.isRefreshing,
                    // Fix wave part 2 (item C): surfaces a queued/offline
                    // "create" outbox row that hasn't landed on the server
                    // yet — without it a create sheet dismisses into
                    // apparent nothing until the next successful drain.
                    pending: viewModel.pendingCreates.map {
                        ItemsListView.PendingRow(id: $0.id, kind: $0.kind, title: $0.title,
                                                  isFailed: $0.lastError != nil, error: $0.lastError)
                    }
                ),
                scope: Binding(get: { viewModel.scope }, set: { viewModel.scope = $0 }),
                convoID: viewModel.convoID,
                thumbnail: { _ in nil },
                onSelect: { path.append($0.id) },
                onMove: { id, index in Task { await viewModel.move(itemID: id, toIndex: index) } },
                onCreate: { showCreate = true },
                onOpenConversation: { id in close(); onOpenConversation(id) }
            )
            .navigationTitle("Tasks & decisions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { close() }
                }
            }
            .navigationDestination(for: String.self) { id in
                ItemDetailHost(itemID: id, session: session, currentConvoID: viewModel.convoID,
                               onOpenConversation: { c in close(); onOpenConversation(c) })
            }
        }
        .background(.background)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16))
        .shadow(radius: 12)
        .sheet(isPresented: $showCreate) {
            NewItemSheet { kind, title, itemBody in
                Task { await viewModel.create(kind: kind, title: title, body: itemBody) }
            }
        }
        // `conversationTitles()` — a plain id→title scan, cheap enough to
        // re-run on every scope switch (Task 10 landed this on
        // `JournalStore+Items.swift` while this task was in flight; using
        // it here instead of hand-rolling the same map keeps the two apps
        // on one source of truth).
        .task(id: viewModel.scope) {
            guard let deps else { return }
            originTitles = (try? deps.journalStore(for: session).conversationTitles()) ?? [:]
        }
        .alert("Tracker", isPresented: Binding(get: { viewModel.error != nil }, set: { if !$0 { viewModel.error = nil } })) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
    }
}

/// Create-item sheet: kind picker, title, free-text body. Mirrors the Mac
/// pane's create sheet (Task 10) with iOS `Form` chrome.
private struct NewItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ItemKind = .task
    @State private var title: String = ""
    @State private var itemBody: String = ""
    let onCreate: (ItemKind, String, String) -> Void

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(ItemKind.allCases, id: \.self) { k in
                        Label(ItemGlyph.label(k), systemImage: ItemGlyph.symbol(k)).tag(k)
                    }
                }
                Section {
                    TextField("Title", text: $title)
                } header: {
                    Text("Title")
                }
                Section {
                    TextEditor(text: $itemBody)
                        .frame(minHeight: 120)
                } header: {
                    Text("Details")
                }
            }
            .navigationTitle("New item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(kind, title, itemBody)
                        dismiss()
                    }
                    .disabled(!canCreate)
                }
            }
        }
    }
}
