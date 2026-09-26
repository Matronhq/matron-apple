import SwiftUI
import UIKit

/// Measures SwiftUI content off-screen with one reused hosting controller —
/// the height it would take in the SwiftUI timeline's `VStack` (a nil
/// vertical proposal, i.e. `fixedSize(vertical:)`), at the current Dynamic
/// Type size. Main thread only; results are cached by the caller.
@MainActor
final class HostedSizer {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))

    init() {
        host.sizingOptions = []
        host.view.backgroundColor = .clear
    }

    func height<V: View>(of view: V, width: CGFloat, sizeCategory: UIContentSizeCategory) -> CGFloat {
        // `traitOverrides.preferredContentSizeCategory` is write-only until
        // a first override exists — reading it back before any override is
        // set raises `NSInternalInconsistencyException` ("no override"), so
        // this always assigns rather than comparing against the prior value.
        host.traitOverrides.preferredContentSizeCategory = sizeCategory
        host.rootView = AnyView(view.fixedSize(horizontal: false, vertical: true))
        return ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}
