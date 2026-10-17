import AppKit
import SwiftUI

/// What a hosted cell draws: its owner (the controller that owns the table,
/// which owns the cell) turns an `Equatable` content value into SwiftUI.
/// The cell holds the provider weakly.
@MainActor
protocol HostedRowBodyProvider: AnyObject {
    /// Everything the row draws. Two equal values must render the same.
    associatedtype HostedContent: Equatable
    associatedtype HostedBody: View
    /// The row's SwiftUI, before the cell frames it to its width.
    func hostedCellBody(_ content: HostedContent) -> HostedBody
    /// The cell is about to be reused: drop any decoration the provider
    /// added to it (the timeline's jump flash).
    func hostedCellWillBeReused(_ cell: NSTableCellView)
}

extension HostedRowBodyProvider {
    func hostedCellWillBeReused(_ cell: NSTableCellView) {}
}

/// The root of every hosted cell: one concrete, `Equatable` type built from
/// what the row draws and the width it is hosted at. A recycled host then
/// diffs one row into another instead of tearing down and rebuilding a
/// type-erased tree, and an identical reconfigure writes nothing at all
/// (`MacHostedRowView.applyContent`).
///
/// The row's SwiftUI comes from the provider's `hostedCellBody`, read
/// through a weak reference.
struct HostedRowRoot<Provider: HostedRowBodyProvider>: View, Equatable {
    /// `nil`: a fresh or recycled cell with nothing to show.
    let content: Provider.HostedContent?
    let width: CGFloat
    weak var source: Provider?

    static var empty: Self { HostedRowRoot(content: nil, width: 0, source: nil) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content && lhs.width == rhs.width && lhs.source === rhs.source
    }

    var body: some View {
        if let content, let source {
            source.hostedCellBody(content)
                .frame(width: width)
        }
    }
}

/// A table row drawn by SwiftUI: one `NSHostingView` filling the cell.
/// Hosted views may read live state themselves, so their height can change
/// after the row was measured; the cell reports that through
/// `onHeightChange`, off its own layout pass.
///
/// The content is hosted at the cell's width (`.frame(width:)`), so a
/// measurer that sizes the same view at the same width agrees with it, and
/// a report means the content really changed.
final class MacHostedRowView<Provider: HostedRowBodyProvider>: NSTableCellView {
    typealias Root = HostedRowRoot<Provider>

    /// `(rowID, newHeight)`, delivered on a later main-queue turn — never
    /// from inside `layout()`, so the receiver may touch the table.
    var onHeightChange: ((String, CGFloat) -> Void)?

    private let host = ReportingHostingView<Root>(rootView: Root.empty)
    private var rowID = ""
    private var expectedHeight: CGFloat = 0
    private var content: Provider.HostedContent?
    private weak var source: Provider?
    /// What `host` shows now: a configure or layout that would build an
    /// equal root writes nothing.
    private var hostedRoot = Root.empty
    /// `host.rootView` writes since init (test seam).
    private(set) var rootViewWriteCountForTesting = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.sizingOptions = [.intrinsicContentSize]
        // The host is framed by autoresizing, so a SwiftUI size change (a
        // card answered, an image landing) re-lays out only the HOST —
        // nothing re-runs this cell's `layout()`, so the report would never
        // fire. The host forwards its own layout passes; the cell re-lays
        // out only when the content's height really moved.
        host.onContentMayHaveResized = { [weak self] in self?.hostContentMayHaveResized() }
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(rowID: String, expectedHeight: CGFloat, content: Provider.HostedContent,
                   source: Provider) {
        self.rowID = rowID
        self.expectedHeight = expectedHeight
        self.content = content
        self.source = source
        applyContent()
        needsLayout = true
    }

    private var hasContent: Bool { content != nil }

    private func applyContent() {
        guard hasContent, bounds.width > 0 else { return }
        let root = Root(content: content, width: bounds.width, source: source)
        guard root != hostedRoot else { return }
        setRoot(root)
    }

    private func setRoot(_ root: Root) {
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
    /// a constraint engine each time (a large share of busy scroll time).
    private func hostContentMayHaveResized() {
        guard hasContent, bounds.width > 0, !needsLayout else { return }
        needsLayout = true
    }

    /// Keeps the hosted root: the table calls this on DEQUEUE, right before
    /// `configure`, so an `EmptyView` swap here never emptied a queued host
    /// — it only made every reuse a teardown plus a full rebuild. The next
    /// root now diffs from the row this host last showed (no write at all
    /// when it is that same row). A queued host is out of the window and
    /// does no work meanwhile.
    override func prepareForReuse() {
        super.prepareForReuse()
        source?.hostedCellWillBeReused(self)
        content = nil
        source = nil
        rowID = ""
        expectedHeight = 0
    }
}
