import SwiftUI

/// Wraps a transient `Bool` and produces a derived flag that stays
/// `true` for at least `duration` once shown. Used to keep brief
/// loading indicators (e.g. `PaginatingHeader` while
/// `ChatViewModel.isPaginatingBackward`) visible long enough to be
/// perceptible — a 50ms paginate that completes from local cache
/// otherwise barely registers behind the SwiftUI fade-in animation.
///
/// Behaviour:
///   - `isActive` flips `true`  → derived flag flips `true` immediately
///   - `isActive` flips `false` → derived flag holds `true` for
///                                `minimumDuration`, then flips
///                                `false` (unless `isActive` flipped
///                                back to `true` in the meantime).
///
/// The hide is driven by a cancellable Task so a flurry of
/// rapid-fire toggles collapses into "true for at least
/// minimumDuration after the last truth", rather than a stuttering
/// chain of show/hide animations.
public struct MinDisplayDuration<Content: View>: View {
    private let isActive: Bool
    private let minimumDuration: Duration
    private let content: (Bool) -> Content

    @State private var derived: Bool = false
    @State private var hideTask: Task<Void, Never>?

    public init(
        while isActive: Bool,
        minimumDuration: Duration = .milliseconds(500),
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.isActive = isActive
        self.minimumDuration = minimumDuration
        self.content = content
    }

    public var body: some View {
        content(derived)
            .onChange(of: isActive, initial: true) { _, newValue in
                hideTask?.cancel()
                hideTask = nil
                if newValue {
                    derived = true
                } else if derived {
                    let duration = minimumDuration
                    hideTask = Task { @MainActor in
                        try? await Task.sleep(for: duration)
                        if !Task.isCancelled {
                            derived = false
                        }
                    }
                }
            }
    }
}
