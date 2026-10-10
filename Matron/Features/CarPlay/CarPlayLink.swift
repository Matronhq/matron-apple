import SwiftUI
import MatronModels
import MatronViewModels

/// What the iPhone's screens and the car's scene need to know about each
/// other. They are separate scenes of one process, and either can be the
/// first, or the only, one connected: the car starts the app with the
/// phone locked in a pocket.
@MainActor
@Observable
final class CarPlayLink {
    static let shared = CarPlayLink()

    /// Voice mode is running on the car's display. One microphone: while
    /// it is, the iPhone offers neither voice mode nor a voice note.
    private(set) var carIsActive = false

    /// Whether the iPhone holds the microphone (a voice note being
    /// recorded, or its own voice mode). Set by the app shell; the car
    /// does not open over it.
    @ObservationIgnored var phoneHoldsMicrophone: () -> Bool = { false }

    /// The signed-in session, as the iPhone's window last published it.
    /// `nil` before the window has restored one: the car then restores it
    /// itself.
    @ObservationIgnored private(set) var session: UserSession?
    /// Called when the user signs out on the iPhone.
    @ObservationIgnored var onSignedOut: (() -> Void)?
    /// Called when a session appears: a sign-in, or one restored at launch.
    @ObservationIgnored var onSignedIn: (() -> Void)?

    func setCarActive(_ active: Bool) {
        if carIsActive != active { carIsActive = active }
    }

    func publish(session: UserSession?) {
        let signedOut = self.session != nil && session == nil
        let signedIn = self.session == nil && session != nil
        self.session = session
        if signedOut { onSignedOut?() }
        if signedIn { onSignedIn?() }
    }
}

/// One microphone between the iPhone and a car's display. The shell tells
/// the car when the iPhone holds it; while voice mode runs on the car, no
/// voice note can be recorded on the iPhone (the same rule the iPhone's
/// own voice mode sets).
struct CarPlayMicrophoneRule: ViewModifier {
    let voiceNotes: VoiceNoteSession
    let nav: AppShellNavigation

    func body(content: Content) -> some View {
        content
            .task {
                CarPlayLink.shared.phoneHoldsMicrophone = { [voiceNotes, nav] in
                    voiceNotes.isRecording || nav.voiceMode != nil
                }
                if CarPlayLink.shared.carIsActive { apply(true) }
            }
            .onChange(of: CarPlayLink.shared.carIsActive) { _, active in apply(active) }
    }

    private func apply(_ carIsActive: Bool) {
        // A note still waiting on its permission prompt is not recording
        // yet: it is dropped.
        if carIsActive { voiceNotes.cancel() }
        voiceNotes.isVoiceModeOn = carIsActive
    }
}
