import SwiftUI

/// The mission card's red "Needs you · n" pill (spec §3.2). Deliberately
/// not `NeedsYouBadge` (orange, a bare count on chat rows): on a card it is
/// the loudest thing, and says what it means. Draws nothing at zero.
public struct NeedsYouPill: View {
    private let count: Int
    public init(count: Int) { self.count = count }

    public var body: some View {
        if count > 0 {
            Text("Needs you · \(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.red, in: Capsule())
                .fixedSize()
                .accessibilityLabel(count == 1 ? "1 item needs you" : "\(count) items need you")
        }
    }
}
