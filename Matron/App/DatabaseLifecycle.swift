import SwiftUI
import MatronJournal

/// The app-level half of `DatabaseSuspensionController`: turns scene-phase
/// changes into its foreground/background transitions.
///
/// Driven from the ROOT of `MatronApp`'s window content, not from the
/// signed-in view. It used to live in the signed-in branch's phase handler,
/// so a process backgrounded on the sign-in screen — including one still
/// running a sign-out teardown against the App Group databases — never
/// suspended them (Bugbot "Sign-in path skips database suspension").
///
/// `beforeSuspending` is where background work that needs the databases
/// claims its activity (the outbox grace, when a session exists). It runs
/// BEFORE the background transition is reported, so the controller already
/// sees the claim when it decides; the other order would suspend and
/// immediately resume under the work's first write.
@MainActor
enum DatabaseLifecycle {
    static func sceneDidChange(to phase: ScenePhase,
                               controller: DatabaseSuspensionController = .shared,
                               beforeSuspending: () -> Void) {
        if phase == .background {
            beforeSuspending()
            controller.setInBackground(true)
        } else {
            // .inactive on the way back up counts: the UI is about to
            // render and write again.
            controller.setInBackground(false)
        }
    }
}
