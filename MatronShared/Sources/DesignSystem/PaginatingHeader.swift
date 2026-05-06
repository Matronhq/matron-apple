import SwiftUI

/// Small "Loading earlier messages…" pill shown at the top of the
/// chat ScrollView while a backward paginate is in flight. Used by
/// both `ChatView` (iOS) and `MacChatView` as an `.overlay(alignment:
/// .top)` so the spinner floats over the topmost content rather than
/// pushing the LazyVStack around — animating layout shifts during
/// scroll-up paginate would yank the user's apparent reading
/// position, which defeats the point of an unobtrusive indicator.
///
/// Gated on `ChatViewModel.isPaginatingBackward` upstream — this
/// view itself doesn't know about the view-model, callers wrap it in
/// the appropriate visibility check + transition. The `.transition`
/// + `.animation` are applied at the call site so iOS / Mac can
/// share the same shape without forcing a SwiftUI animation type
/// across both platforms.
public struct PaginatingHeader: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading earlier messages…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading earlier messages")
    }
}
