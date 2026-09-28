import AppKit
import SwiftUI

/// A table-timeline row drawn by today's SwiftUI views (tool calls, cards,
/// markers, images…): one `NSHostingView` filling the cell. Hosted views read
/// live view-model state themselves, so their height can change after the
/// row was measured; the cell reports that through `onHeightChange`.
///
/// The content is hosted at the cell's width (`.frame(width:)`), exactly as
/// `MacTimelineMeasurer.hostedHeight` measures it, so a report means the
/// content really changed, not that the two measured differently.
final class MacHostedRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("timeline.hosted")

    /// `(rowID, newHeight)`, delivered on a later main-queue turn — never
    /// from inside `layout()`, so the receiver may touch the table.
    var onHeightChange: ((String, CGFloat) -> Void)?

    private let host = ReportingHostingView(rootView: AnyView(EmptyView()))
    private var rowID = ""
    private var expectedHeight: CGFloat = 0
    private var content: AnyView?
    /// The width `content` was last hosted at.
    private var hostedWidth: CGFloat = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.sizingOptions = [.intrinsicContentSize]
        // The host is framed by autoresizing, so a SwiftUI size change (an
        // ask card answered, an image landing) re-lays out only the HOST —
        // nothing re-runs this cell's `layout()`, and the report never
        // fired (Task 9). The host forwards its own layout passes; the cell
        // re-lays out only when the content's height really moved.
        host.onContentMayHaveResized = { [weak self] in self?.hostContentMayHaveResized() }
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(rowID: String, expectedHeight: CGFloat, content: AnyView) {
        self.rowID = rowID
        self.expectedHeight = expectedHeight
        self.content = content
        hostedWidth = -1
        applyContent()
        needsLayout = true
    }

    private func applyContent() {
        guard let content, bounds.width > 0, bounds.width != hostedWidth else { return }
        hostedWidth = bounds.width
        host.rootView = AnyView(content.frame(width: bounds.width))
    }

    override func layout() {
        super.layout()
        applyContent()
        guard content != nil, bounds.width > 0 else { return }
        let height = host.fittingSize.height
        guard abs(height - expectedHeight) > 0.5 else { return }
        // Once per change: the next layout at this height stays quiet.
        expectedHeight = height
        let rowID = rowID
        DispatchQueue.main.async { [weak self] in
            self?.onHeightChange?(rowID, height)
        }
    }

    private func hostContentMayHaveResized() {
        guard content != nil, bounds.width > 0, abs(host.fittingSize.height - expectedHeight) > 0.5 else { return }
        needsLayout = true
    }

    func flash() { TimelineRowFlash.flash(in: self) }

    override func prepareForReuse() {
        super.prepareForReuse()
        TimelineRowFlash.remove(from: self)
        host.rootView = AnyView(EmptyView())
        content = nil
        rowID = ""
        expectedHeight = 0
        hostedWidth = -1
    }
}

/// Tells its cell whenever SwiftUI may have resized the content: an update
/// of the hosted graph lays the host out (observed on macOS 26, occluded
/// window included) and, with `.intrinsicContentSize`, may also invalidate
/// its intrinsic size — either one is forwarded.
private final class ReportingHostingView: NSHostingView<AnyView> {
    var onContentMayHaveResized: (() -> Void)?

    override func layout() {
        super.layout()
        onContentMayHaveResized?()
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentMayHaveResized?()
    }
}
