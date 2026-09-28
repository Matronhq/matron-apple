import UIKit
import SwiftUI

/// How the timeline hosts SwiftUI content inside its cells.
///
/// The timeline's layout gives every hosted piece its frame, and the piece
/// has to draw there. `UIHostingConfiguration` lays its content out inside
/// the safe area it inherits, so a cell that sits in one drew its content
/// somewhere else: measured on the iOS 26.2 simulator, a pills row whose
/// cell lay under a 62 pt top safe area drew its pill 10.7 pt lower, out
/// of the bottom of its row. A cell is in a safe area under the navigation
/// bar as it scrolls, beside the notch in landscape and above the home
/// indicator. So hosted content ignores the safe area.
enum TimelineHosting {
    /// One `Content` type for every configuration, real content and reuse
    /// placeholder alike: a content view traps when it is given a
    /// configuration of a different type from the one that made it.
    static func configuration(_ content: AnyView) -> UIHostingConfiguration<AnyView, EmptyView> {
        UIHostingConfiguration { AnyView(content.ignoresSafeArea()) }.margins(.all, 0)
    }

    static var placeholder: UIHostingConfiguration<AnyView, EmptyView> {
        configuration(AnyView(EmptyView()))
    }
}

/// A timeline row rendered by existing SwiftUI views (`HostedTimelineRow`)
/// through `UIHostingConfiguration`, at the frame the layout gives it. The
/// content lays out at its ideal height (`fixedSize(vertical:)` — what the
/// measurement used) pinned to the top; when that height changes on its own
/// the cell reports it once, off the layout pass, and the controller
/// re-measures only this row.
///
/// Managed as a manual content view (`UIHostingConfiguration.makeContentView()`
/// added to `contentView`, frame kept in sync in `layoutSubviews`) rather
/// than through `self.contentConfiguration` — setting `contentConfiguration`
/// directly on a bare `UICollectionViewCell` never materializes a content
/// view unless the cell is inside a live `UICollectionView`'s reuse/apply
/// cycle (confirmed: `contentView.subviews` stayed empty here even after an
/// explicit `layoutIfNeeded()` on a window-mounted cell). `TextMessageCell`'s
/// hosted pieces and `TimelineFooterView` below already avoid this trap the
/// same way.
///
/// The content ignores the safe area: see `TimelineHosting`.
final class HostedRowCell: UICollectionViewCell {
    private(set) var rowID: String?
    private var expectedHeight: CGFloat = 0
    var onHeightChange: ((String, CGFloat) -> Void)?
    private var hosted: (UIView & UIContentView)?

    func configure(rowID: String, expectedHeight: CGFloat, content: AnyView) {
        self.rowID = rowID
        self.expectedHeight = expectedHeight
        let configuration = hostedConfiguration(content)
        if let hosted {
            hosted.configuration = configuration
        } else {
            let view = configuration.makeContentView()
            contentView.addSubview(view)
            hosted = view
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hosted?.frame = contentView.bounds
    }

    /// One shape for every configuration this cell ever assigns (real
    /// content AND the reuse placeholder) — `UIHostingConfiguration`'s
    /// content view traps if `.configuration` is later set to a DIFFERENT
    /// `Content` type than the one it was created with, and the modifier
    /// chain around `content` (not just `content` itself) is part of that
    /// type. Building both from this one function, with the opaque `some
    /// UIContentConfiguration` return type resolving to one concrete type,
    /// keeps `configure()` and `prepareForReuse()` from drifting apart.
    private func hostedConfiguration(_ content: AnyView) -> some UIContentConfiguration {
        UIHostingConfiguration {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { [weak self] height in
                    self?.report(height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
        }
        .margins(.all, 0)
    }

    private func report(_ height: CGFloat) {
        let rounded = ceil(height)
        guard let rowID, abs(rounded - expectedHeight) > 0.5 else { return }
        expectedHeight = rounded
        // Never re-enter the collection view's layout pass from inside it.
        DispatchQueue.main.async { [weak self] in
            self?.onHeightChange?(rowID, rounded)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        removeJumpFlash()
        rowID = nil
        onHeightChange = nil
        hosted?.configuration = hostedConfiguration(AnyView(EmptyView()))
    }
}

/// The activity indicator ("Thinking…", tool use) — a supplementary view
/// outside the row/anchor space, exactly as the SwiftUI path keeps it a
/// sibling of the scroll-target layout.
final class TimelineFooterView: UICollectionReusableView {
    private var hosted: (UIView & UIContentView)?

    func configure(content: AnyView) {
        let configuration = TimelineHosting.configuration(content)
        if let hosted {
            hosted.configuration = configuration
        } else {
            let view = configuration.makeContentView()
            addSubview(view)
            hosted = view
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hosted?.frame = bounds
    }
}
