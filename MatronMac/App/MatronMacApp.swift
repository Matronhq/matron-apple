import SwiftUI

@main
struct MatronMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowResizability(.contentMinSize)

        // Phase 7 fills this in. For Phase 1 it's a placeholder so `⌘,` opens
        // a window rather than crashing.
        Settings {
            SettingsView()
        }

        // Phase 2 attaches the real menu bar (.commands { CommandMenu… }).
    }
}

private struct ContentView: View {
    var body: some View {
        Text("Matron — Phase 1 scaffold (Mac)")
            .padding()
    }
}

private struct SettingsView: View {
    var body: some View {
        Text("Settings — Phase 7 fills this in.")
            .padding()
            .frame(width: 480, height: 240)
    }
}

// Note: UNUserNotificationCenter.current().delegate registration is
// deferred to Phase 4 (Push & NSE). The Mac receives silent APNs pushes
// in-process via UNUserNotificationCenterDelegate; Phase 4 wires that.
