import SwiftUI

/// Numeric unread-count pill rendered on the trailing edge of a
/// chat-list row. Matches the standard iOS Messages / Mail visual:
/// a small accent-tinted capsule with white text. Values above
/// `cap` render as `cap+` (e.g. `99+`) so a runaway notification
/// queue doesn't blow out the row's horizontal layout.
///
/// Returns `EmptyView` for `count <= 0` so callers don't need a
/// surrounding `if` — the unread row keeps the same layout shape
/// as the no-unread row, just with the pill swapped in.
public struct UnreadBadge: View {
    private let count: Int
    private let cap: Int

    public init(count: Int, cap: Int = 99) {
        self.count = count
        self.cap = cap
    }

    public var body: some View {
        if count > 0 {
            Text(displayText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                // `minWidth: 18` matches Messages' shortest pill so
                // single-digit counts don't collapse to a near-circle
                // — the leading 6pt horizontal padding plus a 1-glyph
                // baseline width was visually too narrow.
                .frame(minWidth: 18)
                .background(Color.accentColor, in: Capsule())
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var displayText: String {
        count > cap ? "\(cap)+" : "\(count)"
    }

    private var accessibilityLabel: String {
        count == 1 ? "1 unread message" : "\(displayText) unread messages"
    }
}
