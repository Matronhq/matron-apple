import SwiftUI
import UIKit

/// Measures SwiftUI content off-screen with one reused hosting controller —
/// the height it would take in the SwiftUI timeline's `VStack` (a nil
/// vertical proposal, i.e. `fixedSize(vertical:)`), at the current Dynamic
/// Type size. Main thread only; results are cached by the caller.
@MainActor
final class HostedSizer {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    /// Mirrors what was last written to `host.traitOverrides`. Reading that
    /// override back throws `NSInternalInconsistencyException` ("no
    /// override") until the first write, so the override itself can't
    /// double as its own "did this change" check.
    private var lastSizeCategory: UIContentSizeCategory?

    init() {
        host.sizingOptions = []
        host.view.backgroundColor = .clear
    }

    func height<V: View>(of view: V, width: CGFloat, sizeCategory: UIContentSizeCategory) -> CGFloat {
        if lastSizeCategory != sizeCategory {
            host.traitOverrides.preferredContentSizeCategory = sizeCategory
            lastSizeCategory = sizeCategory
        }
        host.rootView = AnyView(view.fixedSize(horizontal: false, vertical: true))
        return ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}
