import SwiftUI
import MatronJournal

/// Settings → Sync on this device. "Everything" keeps a copy of every
/// conversation on the phone; "For you only" keeps For you, missions and the
/// Coordinator current and fetches a conversation when it is opened, which
/// saves most of the phone's sync work. Per device: the Mac keeps its own.
///
/// Below the choice, the day's sync counts, so the two can be compared.
struct SyncScopeSettingsSection: View {
    let engine: JournalSyncEngine

    @State private var scope = SyncScope.stored()
    @State private var stats: (today: SyncDayStats, yesterday: SyncDayStats?)?

    var body: some View {
        Section {
            Picker("Keep up to date", selection: $scope) {
                ForEach(SyncScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .onChange(of: scope) { _, new in
                new.store()
                Task {
                    await engine.setSyncScope(new)
                    refreshStats()
                }
            }
            if let stats {
                LabeledContent("Today", value: Self.summary(stats.today))
                if let yesterday = stats.yesterday {
                    LabeledContent("Yesterday", value: Self.summary(yesterday))
                }
            }
        } header: {
            Text("Sync on this device")
        } footer: {
            Text(Self.footer(for: scope))
        }
        .task { refreshStats() }
    }

    private func refreshStats() {
        stats = engine.stats?.snapshot()
    }

    static func footer(for scope: SyncScope) -> String {
        switch scope {
        case .everything:
            "Every conversation is kept on this device as it happens, so any of them opens at once, even offline."
        case .forYou:
            "For you, missions and the Coordinator stay up to date. Other conversations are fetched when you open "
                + "them, so this device does much less work in the background. Offline, only conversations you have "
                + "opened are here. Switching back to Everything reloads this device's copy."
        }
    }

    static func summary(_ day: SyncDayStats) -> String {
        var parts = ["\(day.events.formatted()) events"]
        if day.catchUps > 0 {
            let average = day.catchUpSeconds / Double(day.catchUps)
            parts.append("\(day.catchUps) catch-ups, \(average.formatted(.number.precision(.fractionLength(1)))) s avg")
        }
        if day.conversationFetches > 0 { parts.append("\(day.conversationFetches) opened") }
        // Shown at zero too: none at all is the thing this count is here to reveal.
        parts.append(day.backgroundWakes == 1 ? "1 background wake" : "\(day.backgroundWakes) background wakes")
        return parts.joined(separator: " · ")
    }
}
