import SwiftUI

/// "The agent is waiting on you" count — sibling of `UnreadBadge` with the
/// same font/padding/minWidth metrics so the two sit together on a chat row
/// without a height change, only an orange tint (and the leading glyph)
/// distinguishing it. Returns `EmptyView` for `count <= 0`.
public struct NeedsYouBadge: View {
    private let count: Int
    public init(count: Int) { self.count = count }
    public var body: some View {
        if count > 0 {
            Label(count > 99 ? "99+" : "\(count)", systemImage: "questionmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .frame(minWidth: 18)
                .background(Color.orange, in: Capsule())
                .accessibilityLabel(count == 1 ? "1 item needs you" : "\(count) items need you")
        }
    }
}
