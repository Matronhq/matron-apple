import SwiftUI

/// Warm-up spinner for the chat timeline. Overlaid while the timeline is
/// waiting for its first snapshot (`rows` empty, not yet `settledEmpty`,
/// no error) — the window that used to render as a fully blank message
/// area on chat open.
///
/// Appearance is delayed: a conversation already mirrored locally paints
/// in well under the delay, and flashing a spinner for a few frames reads
/// as jank. Only the genuinely slow path (history fetch over the network,
/// cold store) ever sees it.
public struct TimelineLoadingIndicator: View {
    private let delay: Duration
    @State private var visible = false

    public init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    public var body: some View {
        ProgressView()
            .controlSize(.large)
            .opacity(visible ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                try? await Task.sleep(for: delay)
                if !Task.isCancelled {
                    withAnimation(.easeIn(duration: 0.2)) { visible = true }
                }
            }
            .accessibilityLabel("Loading messages")
    }
}
