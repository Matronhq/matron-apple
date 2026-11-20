import SwiftUI

/// Closes the Settings window when the account signs out.
///
/// Every sign-out path (File → Sign Out, the Account pane's button, and a
/// revoke from another device) ends by clearing the app's session. Without
/// this the Settings window stayed open over the sign-in screen, showing
/// only "Sign in to view settings."
///
/// It acts on the change from signed in to signed out only, so opening
/// Settings from the sign-in screen still shows the placeholder.
struct SettingsSignOutCloser: ViewModifier {
    let isSignedIn: Bool
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.onChange(of: isSignedIn) { wasSignedIn, signedIn in
            if Self.closes(wasSignedIn: wasSignedIn, isSignedIn: signedIn) { dismiss() }
        }
    }

    /// True only for a sign-out: signed in before, signed out now.
    static func closes(wasSignedIn: Bool, isSignedIn: Bool) -> Bool {
        wasSignedIn && !isSignedIn
    }
}

extension View {
    /// See `SettingsSignOutCloser`.
    func closesOnSignOut(isSignedIn: Bool) -> some View {
        modifier(SettingsSignOutCloser(isSignedIn: isSignedIn))
    }
}
