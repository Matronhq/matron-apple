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

    /// `host.traitOverrides.preferredContentSizeCategory` does NOT work: an
    /// off-window `UIHostingController` measures at the SIMULATOR/DEVICE's
    /// current Dynamic Type setting regardless of any trait override
    /// (confirmed on the iOS 26 simulator — an AX3 override at system size
    /// L measured identically to plain `.large`, and a `.large` override at
    /// system size XXL measured identically to AX5). Only the SwiftUI
    /// environment value actually reaches an off-window host, so this sets
    /// `\.dynamicTypeSize` on the measured view itself instead.
    func height<V: View>(of view: V, width: CGFloat, sizeCategory: UIContentSizeCategory) -> CGFloat {
        host.rootView = AnyView(view.fixedSize(horizontal: false, vertical: true)
            .timelineDynamicTypeSize(sizeCategory))
        return ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}
