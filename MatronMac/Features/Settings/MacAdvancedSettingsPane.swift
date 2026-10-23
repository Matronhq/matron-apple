#if os(macOS)
import SwiftUI
import MatronModels
import MatronDesignSystem
import MatronViewModels
import MatronJournal

/// Settings → Advanced: the AppKit view switches and the local store's
/// numbers.
struct MacAdvancedSettingsPane: View {
    /// Read once, when the journal store opens (`AppDependencies`), so a
    /// change applies from the next launch.
    @AppStorage(JournalStore.poolFlagKey) private var usesStorePool = false
    @AppStorage(MacTimelineFlag.key) private var usesAppKitTimeline = MacTimelineFlag.defaultValue
    @AppStorage(MacItemThreadFlag.key) private var usesNativeItemThread = MacItemThreadFlag.defaultValue
    @AppStorage(MacSidebarListFlag.key) private var usesAppKitSidebar = MacSidebarListFlag.defaultValue
    @AppStorage(MacDecisionsListFlag.key) private var usesAppKitDecisions = MacDecisionsListFlag.defaultValue
    @AppStorage(MacItemsListFlag.key) private var usesAppKitItems = MacItemsListFlag.defaultValue
    let session: UserSession
    let deps: AppDependencies
    /// Filled by the `.task` below; `nil` while the read is in flight, which
    /// is what `StorageSettingsRows` renders as a spinner.
    @State private var storage: StorageSettingsRows.Model?

    var body: some View {
        Form {
            Section {
                Toggle("Chat timeline", isOn: $usesAppKitTimeline)
                Toggle("Chat list", isOn: $usesAppKitSidebar)
                Toggle("For you list", isOn: $usesAppKitDecisions)
                Toggle("Tasks & decisions pane", isOn: $usesAppKitItems)
                Toggle("Item threads", isOn: $usesNativeItemThread)
            } header: {
                Text("Faster views (AppKit)")
            } footer: {
                Text("Each switch takes effect the next time that view opens. The AppKit chat list shows every chat in the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                StorageSettingsRows(model: storage)
                Toggle("Concurrent reads", isOn: $usesStorePool)
            } header: {
                Text("Storage")
            } footer: {
                Text("Concurrent reads: reads the chat history beside incoming messages instead of waiting for them. Takes effect the next time Matron opens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: MacSettingsLayout.paneWidth, height: 720)
        .task {
            // On demand only: two file stats and two COUNT(*)s, off the
            // main actor, when the user opens this pane.
            let sizes = await StoreDiagnostics.sizes(
                store: deps.journalStore(for: session), searchURL: deps.searchStoreURL)
            storage = StorageSettingsRows.Model(
                journalBytes: sizes.journalBytes,
                searchBytes: sizes.searchBytes,
                events: sizes.eventCount,
                conversations: sizes.conversationCount,
                launchText: LaunchTimeline.summary(LaunchTimeline.currentLaunch()),
                maintenanceText: StoreDiagnostics.lastMaintenanceText(
                    sizes.lastMaintenance, now: Date()))
        }
    }
}
#endif
