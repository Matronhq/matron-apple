import UIKit
import SwiftUI
import MatronDesignSystem

/// Builds the SwiftUI pieces the native thread hosts, with the environment
/// a hosted view does not inherit across the UIKit boundary.
@MainActor
struct ItemThreadPieceFactory {
    var detail: ItemDetailView
    var environment: TimelineHostedEnvironment

    var router: TimelineLinkRouter {
        TimelineLinkRouter(openTrackerItem: environment.openTrackerItem,
                           openConversation: environment.openConversation,
                           openPageLink: environment.openPageLink,
                           trackerNumberLinks: environment.trackerNumberLinks)
    }

    func view(_ piece: ItemHostedPiece, sizeCategory: UIContentSizeCategory) -> AnyView {
        switch piece {
        case .detail(let piece):
            return AnyView(detail.showing(only: piece)
                .timelineHostedEnvironment(environment)
                .timelineDynamicTypeSize(sizeCategory))
        }
    }
}

/// Measures a hosted piece: its height at a width and the width it takes
/// there (a caption or an image hugs its content; a table fills the
/// width). One reused hosting controller; main thread only.
@MainActor
final class ItemPieceSizer {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))

    init() {
        host.sizingOptions = []
        host.view.backgroundColor = .clear
    }

    func size(of view: AnyView, maxWidth: CGFloat) -> CGSize {
        host.rootView = AnyView(view.fixedSize(horizontal: false, vertical: true))
        let size = host.sizeThatFits(in: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(size.width), maxWidth), height: ceil(size.height))
    }
}

/// A card's ground: the rounded rectangle and shadow its pieces sit on. A
/// cell of its own, under the card's pieces, so a card several screens tall
/// is still one cheap layer and its pieces come and go as they scroll.
final class ItemCardGroundCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        contentView.layer.cornerRadius = 10
        contentView.layer.shadowColor = UIColor.matronBubbleShadow.cgColor
        contentView.layer.shadowOpacity = 1
        contentView.layer.shadowRadius = 2
        contentView.layer.shadowOffset = CGSize(width: 0, height: 1)
        // A layer's colour does not follow the appearance by itself.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ItemCardGroundCell, _) in
            self.contentView.layer.shadowColor = UIColor.matronBubbleShadow.resolvedColor(with: self.traitCollection).cgColor
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        contentView.layer.shadowColor = UIColor.matronBubbleShadow.resolvedColor(with: traitCollection).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(mine: Bool) {
        contentView.backgroundColor = mine ? .matronBubbleMe : .matronBubbleBot
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.layer.shadowPath = UIBezierPath(roundedRect: contentView.bounds, cornerRadius: 10).cgPath
    }
}

/// The text view of a card's body: the chat's message text view
/// (`TimelineBodyTextView`), so it takes presses only on its text and a
/// press on blank space goes to the card, whose long-press menu copies the
/// whole comment. A reading list's bullets are shapes
/// (`MarkdownAttributed.Style.Lists.reading`); copied or read aloud they
/// are the plain bullet.
final class ItemProseTextView: TimelineBodyTextView {
    static func make() -> ItemProseTextView {
        let view = ItemProseTextView()
        TimelineTextViewFactory.configure(view)
        return view
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange
        guard range.length > 0 else { return super.copy(sender) }
        UIPasteboard.general.string = MarkdownAttributed.plainText(copying: plainText(in: range))
    }

    /// Where the tables' placeholders are. A table reads itself to
    /// VoiceOver, a row at a time with its links and Copy Table, so the
    /// text leaves it out of what it reads.
    var tableLocations: Set<Int> = []

    override var accessibilityValue: String? {
        get {
            let all = NSRange(location: 0, length: attributedText.length)
            guard !tableLocations.isEmpty, body.text.length == attributedText.length else {
                return MarkdownAttributed.plainText(copying: plainText(in: all))
            }
            let spoken = TextRowBody(text: body.text, blocks: body.blocks.map { block in
                tableLocations.contains(block.location)
                    ? TextRowBody.Block(segmentIndex: block.segmentIndex, location: block.location, copyText: "")
                    : block
            })
            return MarkdownAttributed.plainText(copying: spoken.copyText(in: all))
        }
        set { super.accessibilityValue = newValue }
    }

    /// The text of `range`, each block's placeholder its block's text.
    private func plainText(in range: NSRange) -> String {
        guard !body.blocks.isEmpty, body.text.length == attributedText.length else {
            return (attributedText.string as NSString).substring(with: range)
        }
        return body.copyText(in: range)
    }
}

/// A card's body: native, selectable text whose links open in the app,
/// over the views of the code blocks, tables and attachments on its lines.
final class ItemTextCell: UICollectionViewCell, UITextViewDelegate {
    private let textView = ItemProseTextView.make()
    private var applied: NSAttributedString?
    private var router = TimelineLinkRouter()

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.delegate = self
        contentView.addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(body: ItemCardBody, router: TimelineLinkRouter) {
        self.router = router
        if applied !== body.body.text {
            textView.attributedText = body.body.text
            applied = body.body.text
        }
        textView.body = body.body
        textView.blockFrames = body.blockFrames
        textView.tableLocations = Set(zip(body.body.blocks, body.blockPieces).compactMap { block, piece in
            if case .table = piece.kind { return block.location }
            return nil
        })
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = contentView.bounds
    }

    /// Only the text view's presses: the cell lies over the card's blocks
    /// and blank space, which take their own.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === contentView ? nil : hit
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        textView.resignFirstResponder()
        textView.selectedTextRange = nil
        router = TimelineLinkRouter()
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                  defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, !router.isSystemLink(url) else { return defaultAction }
        let router = router
        return UIAction { _ in router.route(url) }
    }

    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                  defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        router.menuConfiguration(for: textItem, defaultMenu: defaultMenu)
    }

    /// Whether a press at `point` (in the cell) is the text view's: on its
    /// text, or anywhere while it holds a selection.
    func isTextHit(_ point: CGPoint) -> Bool {
        textView.point(inside: textView.convert(point, from: self), with: nil)
    }

    /// The text view, while it holds a selection (`TimelineSelectionAutoscroller`).
    var selectingTextView: UITextView? {
        textView.isFirstResponder && textView.selectedRange.length > 0 ? textView : nil
    }

    var textViewForTesting: UITextView { textView }
}

/// A fenced code block of a card: the chat timeline's own.
final class ItemCodeCell: UICollectionViewCell {
    private let code = CodeBlockSegmentView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The card's text view reads the code where it sits.
        code.hidesCodeFromAccessibility()
        contentView.addSubview(code)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `cardText` is the whole card's, for the code's edit menu's "Copy
    /// Message", as in the chat.
    func configure(language: String?, code source: String, style: TimelineTextStyle, cardText: String?) {
        code.configure(language: language, code: source, style: style)
        code.messageBodyForEditMenu = { cardText }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        code.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        code.clearSelectionForReuse()
    }
}

/// A table of a card.
final class ItemTableCell: UICollectionViewCell {
    private let table = ItemTableView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // It reads itself to VoiceOver; the card's text leaves it out.
        contentView.addSubview(table)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(layout: ItemTableLayout, router: TimelineLinkRouter) {
        table.configure(layout)
        table.onOpenLink = { router.route($0) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        table.frame = contentView.bounds
    }
}
