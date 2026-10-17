import AppKit
import SwiftUI

/// Tells its cell when SwiftUI may have resized the content: with
/// `.intrinsicContentSize`, a content size change invalidates the host's
/// intrinsic size. A layout pass alone is forwarded only when the intrinsic
/// height it settles on differs from the last one seen, so an ordinary pass
/// (a scroll, a re-mount) never re-lays out the cell.
final class ReportingHostingView<Root: View>: NSHostingView<Root> {
    var onContentMayHaveResized: (() -> Void)?
    private var lastIntrinsicHeight: CGFloat = -1

    override func layout() {
        super.layout()
        let height = intrinsicContentSize.height
        guard abs(height - lastIntrinsicHeight) > 0.5 else { return }
        lastIntrinsicHeight = height
        onContentMayHaveResized?()
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentMayHaveResized?()
    }
}
