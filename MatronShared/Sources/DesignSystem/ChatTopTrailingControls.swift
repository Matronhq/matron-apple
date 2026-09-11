import SwiftUI

/// Floating top-trailing overlay stack for the chat timeline: the Stop
/// pill (when a turn is running) above the "jump to my last message"
/// pill (when the user has scrolled away from the tail) — or the jump
/// pill alone, in Stop's slot, when no turn is running. This is "the one
/// thing scrolling can't find": jumping back to your own last message
/// stays reachable without living permanently in the header toolbar.
///
/// Owns the 16pt trailing / 8pt top padding for the whole stack so the
/// two pills line up on one shared trailing edge; `StopTurnButton` no
/// longer carries its own padding since this is its only host.
public struct ChatTopTrailingControls: View {
    private let showsStop: Bool
    private let showsJump: Bool
    private let onStop: () -> Void
    private let onJump: () -> Void

    public init(
        showsStop: Bool,
        showsJump: Bool,
        onStop: @escaping () -> Void,
        onJump: @escaping () -> Void
    ) {
        self.showsStop = showsStop
        self.showsJump = showsJump
        self.onStop = onStop
        self.onJump = onJump
    }

    /// Pure visibility rule: the jump pill shows once the user has
    /// scrolled away from the live tail, except on the Tasks page (which
    /// has no message timeline to jump within).
    public static func showsJump(isFollowingTail: Bool, isTasksPage: Bool) -> Bool {
        !isFollowingTail && !isTasksPage
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if showsStop {
                StopTurnButton(action: onStop)
            }
            if showsJump {
                JumpToLastOwnMessageButton(action: onJump)
            }
        }
        .padding(.trailing, 16)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.18), value: showsStop)
        .animation(.easeInOut(duration: 0.18), value: showsJump)
    }
}
