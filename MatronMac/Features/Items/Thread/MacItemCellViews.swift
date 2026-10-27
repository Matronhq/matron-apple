import AppKit
import SwiftUI
import MatronDesignSystem

/// A row of the native item thread that the SwiftUI item view draws whole
/// (header, labels, consent card, buttons, divider, a pending reply, the
/// working indicator, a bare status line): one hosting view filling the
/// cell. Hosted views read live state themselves, so their height can
/// change after the row was measured; the cell reports that.
final class MacItemHostedCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("item.hosted")

    /// `(rowID, newHeight)`, on a later main-queue turn — never from inside
    /// `layout()`, so the receiver may touch the table.
    var onHeightChange: ((String, CGFloat) -> Void)?

    private let host = ReportingHostingView<AnyView>(rootView: AnyView(EmptyView()))
    private(set) var rowID = ""
    private var expectedHeight: CGFloat = 0
    private var content = AnyView(EmptyView())
    /// The width the content is hosted at; `-1` until it has one.
    private var hostedWidth: CGFloat = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.sizingOptions = [.intrinsicContentSize]
        host.onContentMayHaveResized = { [weak self] in
            guard let self, !self.rowID.isEmpty, !self.needsLayout else { return }
            self.needsLayout = true
        }
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(rowID: String, expectedHeight: CGFloat, view: AnyView) {
        self.rowID = rowID
        self.expectedHeight = expectedHeight
        content = view
        hostedWidth = -1
        hostAtWidth()
        needsLayout = true
    }

    /// Hosted at the cell's width (`.frame(width:)`), as the sizer measured
    /// it, so `fittingSize` answers the height at that width: a report
    /// means the content changed, not that the two measured differently.
    private func hostAtWidth() {
        guard bounds.width > 0, bounds.width != hostedWidth else { return }
        hostedWidth = bounds.width
        host.rootView = AnyView(content.fixedSize(horizontal: false, vertical: true)
            .frame(width: bounds.width, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top))
    }

    override func layout() {
        super.layout()
        guard !rowID.isEmpty, bounds.width > 0 else { return }
        hostAtWidth()
        let height = ceil(host.fittingSize.height)
        guard abs(height - expectedHeight) > 0.5 else { return }
        // Once per change: the next layout at this height stays quiet.
        expectedHeight = height
        let rowID = rowID
        DispatchQueue.main.async { [weak self] in self?.onHeightChange?(rowID, height) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowID = ""
        expectedHeight = 0
        hostedWidth = -1
    }
}

/// One card of the native item thread: the body or a comment. The ground
/// (bubble colour, corners, shadow), one `MessageBodyView` per text part,
/// and the SwiftUI pieces (caption, attachments, delivery line, the
/// comment's buttons, a status note's line) hosted at the frames the
/// layout gave them.
final class MacItemCardCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("item.card")

    /// `(rowID, piece, newHeight)`: a hosted piece settled at a height
    /// other than the layout's (a voice note's transcript arrived), on a
    /// later main-queue turn.
    var onHeightChange: ((String, ItemDetailView.Piece, CGFloat) -> Void)?

    private let ground = BubbleChromeView(cornerRadius: 10, shadowBlurRadius: 2)
    private var bodies: [MessageBodyView] = []
    private var hosts: [ReportingHostingView<AnyView>] = []
    /// The piece each in-use host shows, and the height it was laid out at.
    private var hostedPieces: [(piece: ItemDetailView.Piece, height: CGFloat)] = []
    private(set) var rowID = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(ground)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Test seams.
    var visibleBodies: [MessageBodyView] { bodies.filter { !$0.isHidden } }
    var visibleHostFrames: [CGRect] { hosts.filter { !$0.isHidden }.map(\.frame) }
    var groundFrame: CGRect { ground.frame }

    func configure(rowID: String, layout: MacItemCardLayout, mine: Bool, dimmed: Bool,
                   factory: MacItemPieceFactory, selection: MessageSelectionController,
                   routing: MacTimelineLinkRouting) {
        self.rowID = rowID
        ground.frame = layout.cardFrame
        ground.isOwn = mine
        var bodyCount = 0
        var hostCount = 0
        hostedPieces = []
        for (part, frame) in zip(layout.parts, layout.frames) {
            // A reply the agent hasn't got yet is drawn like an outbox row:
            // the card dimmed, not the buttons under it.
            let alpha: CGFloat = dimmed && layout.cardFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) ? 0.85 : 1
            switch part {
            case .text(let selectionID, let source, let links):
                if bodyCount == bodies.count {
                    let body = MessageBodyView()
                    body.forcesTextKit1 = true
                    body.keepsScrollPositionOnResize = true
                    bodies.append(body)
                    addSubview(body)
                }
                let body = bodies[bodyCount]
                bodyCount += 1
                body.isHidden = false
                body.alphaValue = alpha
                body.frame = frame
                body.router.openTrackerItem = routing.openTrackerItem
                body.router.openConversation = routing.openConversation
                body.router.openPageLink = routing.openPageLink
                body.router.trackerNumberLinks = routing.trackerNumberLinks
                body.configure(source: source, rendered: MacItemCardGeometry.rendered(source, trackerLinks: links),
                               itemID: selectionID,
                               selectionController: selection)
            case .hosted(let piece):
                if hostCount == hosts.count {
                    let host = ReportingHostingView<AnyView>(rootView: AnyView(EmptyView()))
                    host.sizingOptions = [.intrinsicContentSize]
                    host.onContentMayHaveResized = { [weak self] in
                        guard let self, !self.rowID.isEmpty, !self.needsLayout else { return }
                        self.needsLayout = true
                    }
                    hosts.append(host)
                    addSubview(host)
                }
                let host = hosts[hostCount]
                hostCount += 1
                host.isHidden = false
                host.alphaValue = alpha
                host.frame = frame
                host.rootView = AnyView(factory.view(piece).fixedSize(horizontal: false, vertical: true)
                    .frame(width: frame.width, alignment: .topLeading))
                hostedPieces.append((piece, frame.height))
            }
        }
        ground.alphaValue = dimmed ? 0.85 : 1
        for body in bodies[bodyCount...] where !body.isHidden {
            // Drops its selection id first; `NSView.prepareForReuse` also
            // un-hides, so it goes before the hide.
            body.prepareForReuse()
            body.isHidden = true
        }
        for host in hosts[hostCount...] {
            host.isHidden = true
            host.rootView = AnyView(EmptyView())
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !rowID.isEmpty else { return }
        for (index, host) in hosts.enumerated() where !host.isHidden && index < hostedPieces.count {
            let height = ceil(host.fittingSize.height)
            guard abs(height - hostedPieces[index].height) > 0.5 else { continue }
            hostedPieces[index].height = height
            let (rowID, piece) = (rowID, hostedPieces[index].piece)
            DispatchQueue.main.async { [weak self] in self?.onHeightChange?(rowID, piece, height) }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowID = ""
    }
}
