import SwiftUI
import MatronJournal
import MatronViewModels

/// Settings → Notifications (journal spec 2026-10-01): what may push to the
/// user's devices. The mode and the event switches and the overrides are
/// synced per user, so a change here shows on the Mac at once; "On this
/// device" is this iPhone's alone. Every change is shown at once and taken
/// back if the journal refuses it (`NotifySettingsStore`).
struct NotificationSettingsView: View {
    let store: NotifySettingsStore
    /// The overrides list's row titles, from the local conversation store.
    let title: (String) -> String

    var body: some View {
        Form {
            if store.isSupported == false {
                Section {
                    Text("This server doesn't support notification settings yet.")
                        .foregroundStyle(.secondary)
                }
            } else if let view = store.view {
                modeSection(view.settings)
                eventsSection(view.settings)
                deviceSection(view.deviceLevel)
                overridesSection
                Section {
                } footer: {
                    Text("For quiet hours, use a Focus. Events that don't notify still update the app's lists and unread dots.")
                }
            } else {
                Section {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            if let error = store.errorMessage {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Notifications")
        // On screen entry as well as on every connect: a frame missed while
        // the socket was down is caught here.
        .task { await store.refresh() }
    }

    private func modeSection(_ settings: NotifySettings) -> some View {
        Section {
            Picker("Mode", selection: Binding(
                get: { settings.mode },
                set: { mode in Task { await store.setMode(mode) } }
            )) {
                ForEach(NotifySettings.Mode.allCases, id: \.self) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.title)
                        Text(mode.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Notify me about")
        } footer: {
            if settings.mode == .coordinator && !settings.hasCoordinator {
                Text("Until a Coordinator is set, Coordinator mode acts as Every session.")
            }
        }
    }

    /// Always editable: switching one while on a preset moves to Custom,
    /// starting from that preset's switches (the journal's rule).
    private func eventsSection(_ settings: NotifySettings) -> some View {
        Section {
            ForEach(NotifySettings.Event.allCases, id: \.self) { event in
                if event == .prompts {
                    Toggle(isOn: .constant(true)) {
                        Label(event.title, systemImage: "lock.fill")
                    }
                    .disabled(true)
                    .accessibilityHint("Always on: an unanswered prompt blocks an agent.")
                } else {
                    Toggle(event.title, isOn: Binding(
                        get: { settings.isOn(event) },
                        set: { on in Task { await store.setEvent(event, on: on) } }
                    ))
                }
            }
        } header: {
            Text("Events")
        } footer: {
            if settings.mode != .custom {
                Text("Changing a switch moves you to Custom.")
            }
        }
    }

    private func deviceSection(_ level: NotifyDeviceLevel) -> some View {
        Section("On this device") {
            Picker("On this device", selection: Binding(
                get: { level },
                set: { level in Task { await store.setDeviceLevel(level) } }
            )) {
                ForEach(NotifyDeviceLevel.allCases, id: \.self) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var overridesSection: some View {
        let overrides = store.activeOverrides
        if !overrides.isEmpty {
            Section("Conversation overrides") {
                ForEach(overrides, id: \.convoID) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(row.convoID)).lineLimit(1)
                            Text(store.state(for: row.convoID).summary())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Clear") {
                            Task { await store.clearOverride(convoID: row.convoID) }
                        }
                        .buttonStyle(.borderless)
                    }
                    .swipeActions {
                        Button("Clear", role: .destructive) {
                            Task { await store.clearOverride(convoID: row.convoID) }
                        }
                    }
                }
            }
        }
    }
}
