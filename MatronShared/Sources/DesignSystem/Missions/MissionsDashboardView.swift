import SwiftUI
import MatronModels

/// The Ask button (spec §3.4). A labelled icon: the Mac header shows the
/// title, the iOS toolbar the icon (iOS 26 truncates leading toolbar text).
public struct MissionsDashboardAskButton: View {
    public static let title = "Ask the Coordinator to update"
    let isEnabled: Bool
    let action: () -> Void
    /// `isEnabled: false` while an Ask is in flight or cooling down
    /// (`MissionsDashboardViewModel.canSendAsk`).
    public init(isEnabled: Bool = true, action: @escaping () -> Void) {
        self.isEnabled = isEnabled; self.action = action
    }

    public var body: some View {
        Button(action: action) { Label(Self.title, systemImage: "arrow.triangle.2.circlepath") }
            .disabled(!isEnabled)
            .help(Self.title)
            .accessibilityIdentifier("missions.askCoordinator")
    }
}

/// The Missions dashboard (spec 2026-09-28 §3). A pure leaf view: hosts map
/// `MissionsDashboardViewModel` into `Model`, so this snapshots without a
/// view model — the same contract the old list view had.
public struct MissionsDashboardView: View {
    public struct Model: Equatable {
        public var cards: [DashboardMissionCard]
        public var looseSessions: [DashboardSession]
        public var closed: [Mission]
        /// `false` shows the unsupported message; hosts hide the entry too.
        public var isSupported: Bool
        public var isRefreshing: Bool
        /// When the Coordinator was last asked this session, if pending.
        public var askedAt: Date?
        /// `false` greys the Ask button (an Ask in flight or cooling down).
        public var isAskEnabled: Bool
        public init(cards: [DashboardMissionCard], looseSessions: [DashboardSession], closed: [Mission],
                    isSupported: Bool, isRefreshing: Bool, askedAt: Date? = nil, isAskEnabled: Bool = true) {
            self.cards = cards; self.looseSessions = looseSessions; self.closed = closed
            self.isSupported = isSupported; self.isRefreshing = isRefreshing; self.askedAt = askedAt
            self.isAskEnabled = isAskEnabled
        }
        public var isEmpty: Bool { cards.isEmpty && looseSessions.isEmpty && closed.isEmpty }
    }

    /// One column on an iPhone; two or three on iPad and Mac (spec §3.2).
    public static let columns = [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)]

    let model: Model
    let now: Date?
    let onAction: (MissionsDashboardAction) -> Void
    let onRefresh: () async -> Void
    let onAsk: (() -> Void)?
    @State private var showClosed = false

    public init(model: Model, now: Date? = nil, onAction: @escaping (MissionsDashboardAction) -> Void,
                onRefresh: @escaping () async -> Void, onAsk: (() -> Void)? = nil) {
        self.model = model; self.now = now; self.onAction = onAction; self.onRefresh = onRefresh; self.onAsk = onAsk
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            macHeader
            Divider()
            #endif
            content
        }
        #if os(iOS)
        .background(MatronTimelineBackground())
        #endif
    }

    #if os(macOS)
    private var macHeader: some View {
        HStack(spacing: 12) {
            Text("Missions").font(.headline)
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing") }
            if let onAsk { MissionsDashboardAskButton(isEnabled: model.isAskEnabled, action: onAsk).labelStyle(.titleAndIcon) }
            Button { Task { await onRefresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh").accessibilityLabel("Refresh")
        }
        .padding(.horizontal).padding(.vertical, 8)
    }
    #endif

    @ViewBuilder private var content: some View {
        if !model.isSupported {
            placeholder(ContentUnavailableView("Missions not available", systemImage: "exclamationmark.triangle",
                                               description: Text("Update the journal server to use missions.")))
        } else if model.isEmpty {
            // Only an agent can start one (`mission_start`, spec #74).
            placeholder(ContentUnavailableView("No missions yet", systemImage: "flag.checkered",
                                               description: Text("An agent starts one with mission_start, then posts milestones as the work goes.")))
        } else {
            scroll
        }
    }

    private var scroll: some View {
        ScrollView {
            ticking { now in page(now: now) }
        }
        #if os(iOS)
        .refreshable { await onRefresh() }
        #endif
    }

    /// A fixed clock for snapshots, a minute-aligned tick otherwise, so
    /// "12m ago" keeps moving without the host re-rendering.
    @ViewBuilder private func ticking<Content: View>(@ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        if let now {
            content(now)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in content(context.date) }
        }
    }

    private func page(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let askedAt = model.askedAt { askedCaption(askedAt, now: now) }
            if !model.cards.isEmpty { cardGrid(now: now) }
            if !model.looseSessions.isEmpty { looseSection }
            if !model.closed.isEmpty { closedSection }
        }
        .padding(16)
    }

    private func askedCaption(_ askedAt: Date, now: Date) -> some View {
        Label(MissionsDashboardFormat.askedLabel(askedAt: askedAt, now: now), systemImage: "arrow.triangle.2.circlepath")
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("missions.asked")
    }

    private func cardGrid(now: Date) -> some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 16) {
            ForEach(model.cards) { card in MissionCardView(card: card, now: now, onAction: onAction) }
        }
    }

    private var looseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Not on a mission").font(.headline)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                ForEach(model.looseSessions) { session in
                    LooseSessionCardView(session: session) { onAction(.openSession(session.id)) }
                }
            }
        }
    }

    /// Collapsed by default, today's compact rows inside (spec §3.1).
    private var closedSection: some View {
        DisclosureGroup(isExpanded: $showClosed) {
            VStack(spacing: 0) {
                ForEach(model.closed) { mission in
                    Button { onAction(.openMission(mission.id)) } label: { MissionRowView(row: MissionRowModel(closed: mission)) }
                        .buttonStyle(.plain).foregroundStyle(Color.primary)
                    Divider()
                }
            }
        } label: {
            Text("Closed (\(model.closed.count))").font(.headline)
        }
        .accessibilityIdentifier("missions.closedToggle")
    }

    /// Same shape as `DecisionsListView.placeholder`: on iOS the empty
    /// states still answer pull-to-refresh.
    @ViewBuilder private func placeholder<Content: View>(_ content: Content) -> some View {
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
