import AppKit
import SwiftUI

/// The root of every hosted cell: one concrete, `Equatable` type built from
/// what the row draws and the width it is hosted at (perf follow-ups R1).
/// A recycled host then diffs one row into another instead of tearing down
/// and rebuilding a type-erased tree, and an identical reconfigure writes
/// nothing at all (`MacHostedRowView.applyContent`).
///
/// The row's SwiftUI comes from the controller's `hostedRowBody` — the same
/// view the measurer sizes — read through a weak reference: the controller
/// owns the table, which owns this cell.
struct HostedRowRoot: View, Equatable {
    enum Content: Equatable {
        /// A fresh or recycled cell with nothing to show.
        case empty
        case row(HostedRowContent)
        /// The table's last row: bottom padding plus the activity indicator.
        case footer(label: String?)
    }

    let content: Content
    let width: CGFloat
    weak var source: MacTimelineController?

    static let empty = HostedRowRoot(content: .empty, width: 0, source: nil)

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content && lhs.width == rhs.width && lhs.source === rhs.source
    }

    var body: some View {
        switch content {
        case .empty:
            EmptyView()
        case .row(let row):
            if let source {
                // Top-aligned: the row's height includes the gap below it.
                source.hostedRowBody(row)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .frame(width: width)
            }
        case .footer(let label):
            MacTimelineController.footerContent(label: label)
                .frame(width: width)
        }
    }
}

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

    private let host = ReportingHostingView(rootView: HostedRowRoot.empty)
    private var rowID = ""
    private var expectedHeight: CGFloat = 0
    private var content: HostedRowRoot.Content = .empty
    private weak var source: MacTimelineController?
    /// What `host` shows now: a configure or layout that would build an
    /// equal root writes nothing (perf follow-ups R1 (b)).
    private var hostedRoot = HostedRowRoot.empty
    /// `host.rootView` writes since init (perf follow-ups R1 test seam).
    private(set) var rootViewWriteCountForTesting = 0

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

    func configure(rowID: String, expectedHeight: CGFloat, content: HostedRowRoot.Content,
                   source: MacTimelineController) {
        self.rowID = rowID
        self.expectedHeight = expectedHeight
        self.content = content
        self.source = source
        applyContent()
        needsLayout = true
    }

    private var hasContent: Bool { content != .empty }

    private func applyContent() {
        guard hasContent, bounds.width > 0 else { return }
        let root = HostedRowRoot(content: content, width: bounds.width, source: source)
        guard root != hostedRoot else { return }
        setRoot(root)
    }

    private func setRoot(_ root: HostedRowRoot) {
        hostedRoot = root
        host.rootView = root
        rootViewWriteCountForTesting += 1
    }

    override func layout() {
        super.layout()
        applyContent()
        guard hasContent, bounds.width > 0 else { return }
        let height = host.fittingSize.height
        guard abs(height - expectedHeight) > 0.5 else { return }
        // Once per change: the next layout at this height stays quiet.
        expectedHeight = height
        let rowID = rowID
        DispatchQueue.main.async { [weak self] in
            self?.onHeightChange?(rowID, height)
        }
    }

    /// Only marks the cell for layout: `layout()` measures once and dedupes
    /// against `expectedHeight`. Never `fittingSize` here — this runs from
    /// inside the host's own layout/invalidation, and a fitting pass builds
    /// a constraint engine each time (~15% of busy scroll time, Task 12).
    private func hostContentMayHaveResized() {
        guard hasContent, bounds.width > 0, !needsLayout else { return }
        needsLayout = true
    }

    func flash() { TimelineRowFlash.flash(in: self) }

    override func prepareForReuse() {
        super.prepareForReuse()
        TimelineRowFlash.remove(from: self)
        setRoot(.empty)
        content = .empty
        source = nil
        rowID = ""
        expectedHeight = 0
    }
}

/// Tells its cell when SwiftUI may have resized the content: with
/// `.intrinsicContentSize`, a content size change invalidates the host's
/// intrinsic size. A layout pass alone is forwarded only when the intrinsic
/// height it settles on differs from the last one seen, so an ordinary pass
/// (a scroll, a re-mount) never re-lays out the cell.
private final class ReportingHostingView: NSHostingView<HostedRowRoot> {
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
