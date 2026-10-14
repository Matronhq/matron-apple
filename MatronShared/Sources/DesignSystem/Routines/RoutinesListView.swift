import SwiftUI
import MatronModels

/// Settings ▸ Coordinator ▸ Routines: the user's Coordinator routines,
/// sorted by name, each with what sets it off, its next and last fire, a
/// pause switch and Run now. A pure leaf view: hosts map
/// `RoutinesViewModel` into `Model` and handle the taps.
public struct RoutinesListView: View {
    public struct Model: Equatable {
        /// `nil` until the first load lands.
        public var routines: [Routine]?
        /// `false` once the journal has 404'd `GET /routines`.
        public var isSupported: Bool
        public var isLoading: Bool
        public var loadError: String?
        /// Routines with a pause or run request in flight.
        public var busyIDs: Set<String>
        public init(routines: [Routine]?, isSupported: Bool, isLoading: Bool, loadError: String? = nil,
                    busyIDs: Set<String> = []) {
            self.routines = routines; self.isSupported = isSupported; self.isLoading = isLoading
            self.loadError = loadError; self.busyIDs = busyIDs
        }
    }

    public struct Actions {
        public var select: (String) -> Void
        public var setEnabled: (String, Bool) -> Void
        public var run: (String) -> Void
        public var refresh: () async -> Void
        public init(select: @escaping (String) -> Void, setEnabled: @escaping (String, Bool) -> Void,
                    run: @escaping (String) -> Void, refresh: @escaping () async -> Void) {
            self.select = select; self.setEnabled = setEnabled; self.run = run; self.refresh = refresh
        }
    }

    public static let caption = "Prompts the journal sends your Coordinator on a schedule, or when something needs a look. Pause one to stop it without losing it."

    let model: Model
    let actions: Actions
    var now: Date?

    public init(model: Model, actions: Actions, now: Date? = nil) {
        self.model = model; self.actions = actions; self.now = now
    }

    public var body: some View {
        List {
            if !model.isSupported {
                note("This journal doesn't have routines yet. Update the journal server to use them.")
            } else if let routines = model.routines {
                Section {
                    if routines.isEmpty {
                        note("No routines yet. Add one, or ask your Coordinator to.")
                    }
                    ForEach(routines) { routine in
                        RoutineRowView(routine: routine, isBusy: model.busyIDs.contains(routine.id),
                                       now: now ?? Date(), actions: actions)
                    }
                } footer: {
                    Text(Self.caption).fixedSize(horizontal: false, vertical: true)
                }
                if let loadError = model.loadError {
                    note("Couldn't refresh: \(loadError)")
                }
            } else if let loadError = model.loadError {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn't load routines: \(loadError)").foregroundStyle(.orange)
                    Button("Try again") { Task { await actions.refresh() } }
                }
                .font(.caption)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .refreshable { await actions.refresh() }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One routine's row: title and name, what sets it off, next and last
/// fire, and the pause switch. Tapping the text opens the editor; Run now
/// sits in the context menu and the swipe actions.
struct RoutineRowView: View {
    let routine: Routine
    let isBusy: Bool
    let now: Date
    let actions: RoutinesListView.Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { actions.select(routine.id) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(routine.title).font(.body.weight(.medium))
                            .foregroundStyle(routine.enabled ? .primary : .secondary)
                        if !routine.enabled {
                            Text("Paused").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(routine.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Label(routine.whenWords, systemImage: routine.isTriggered ? "bolt" : "clock")
                        .font(.caption)
                    ForEach(Self.statusLines(routine, now: now), id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                    if routine.lastFireFailed, let outcome = routine.lastOutcomeWords {
                        Text(outcome).font(.caption).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("routine.row.\(routine.name)")
            VStack(alignment: .trailing, spacing: 6) {
                Toggle("Active", isOn: Binding(get: { routine.enabled },
                                               set: { actions.setEnabled(routine.id, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(isBusy)
                    .accessibilityLabel(routine.enabled ? "Active" : "Paused")
                    .accessibilityIdentifier("routine.enabled.\(routine.name)")
                #if os(macOS)
                Button("Run now") { actions.run(routine.id) }
                    .controlSize(.small)
                    .disabled(isBusy)
                #endif
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button { actions.run(routine.id) } label: { Label("Run now", systemImage: "play") }
            Button { actions.setEnabled(routine.id, !routine.enabled) } label: {
                Label(routine.enabled ? "Pause" : "Resume", systemImage: routine.enabled ? "pause" : "playpause")
            }
            Button { actions.select(routine.id) } label: { Label("Edit", systemImage: "pencil") }
        }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            Button { actions.run(routine.id) } label: { Label("Run now", systemImage: "play") }
                .tint(.accentColor)
        }
        #endif
    }

    /// "Next: today at 18:30" (scheduled, active) and "Last: 2 hours ago ·
    /// Delivered". A failed last outcome gets its own orange line instead.
    static func statusLines(_ routine: Routine, now: Date) -> [String] {
        var lines: [String] = []
        if let next = routine.nextAt, routine.enabled, !routine.isTriggered {
            lines.append("Next: " + when(next, now: now))
        }
        if let last = routine.lastFiredAt {
            var line = "Last: " + RelativeDateTimeFormatter().localizedString(for: last, relativeTo: now)
            if !routine.lastFireFailed, let outcome = routine.lastOutcomeWords { line += " · \(outcome)" }
            lines.append(line)
        } else {
            lines.append("Never fired")
        }
        return lines
    }

    /// "today at 18:30", "tomorrow at 07:05", "Mon 20 Oct at 08:00" (times
    /// in the device's own format and zone).
    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " at \(time)"
    }
}
