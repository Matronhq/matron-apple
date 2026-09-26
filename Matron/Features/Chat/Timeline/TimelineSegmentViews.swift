import UIKit
import SwiftUI
import MatronDesignSystem

/// UIKit twin of `CodeBlock`: language label + copy button, then the code
/// unwrapped in a horizontally scrolling rounded box. Selectable (TextKit 2).
final class CodeBlockSegmentView: UIView {
    private let languageLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let codeView = TimelineTextViewFactory.make()
    private var code = ""
    /// The (code, style) pair last applied to `codeView.attributedText` —
    /// while a message is streaming, `configure` runs every frame, and
    /// reassigning the SAME text each time clears any in-progress selection
    /// inside the code block. The style is part of the key: a Dynamic Type
    /// change re-measures with the SAME code but a different
    /// `TimelineTextStyle` (see `TextMessageCell.AppliedTable`) and must
    /// still re-render.
    private struct AppliedCode: Equatable {
        let code: String
        let style: TimelineTextStyle
    }
    private var appliedCode: AppliedCode?
    private var codeSize: CGSize = .zero
    private var headerHeight: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        languageLabel.textColor = .secondaryLabel
        languageLabel.adjustsFontForContentSizeCategory = false
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.image = UIImage(systemName: "doc.on.doc")
        copyButton.configuration = configuration
        copyButton.accessibilityLabel = "Copy"
        copyButton.addAction(UIAction { [weak self] _ in self?.copyCode() }, for: .primaryActionTriggered)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.backgroundColor = .systemGray6
        scrollView.layer.cornerRadius = 6
        scrollView.clipsToBounds = true
        codeView.textContainer.widthTracksTextView = false
        codeView.textContainer.size = CGSize(width: CodeBlockMetrics.unboundedWidth, height: .greatestFiniteMagnitude)
        scrollView.addSubview(codeView)
        addSubview(languageLabel)
        addSubview(copyButton)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(language: String?, code: String, style: TimelineTextStyle) {
        self.code = code
        languageLabel.font = style.codeHeaderFont
        languageLabel.text = (language?.isEmpty ?? true) ? "code" : language
        copyButton.configuration?.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(font: style.copyIconFont)
        let applied = AppliedCode(code: code, style: style)
        if appliedCode != applied {
            codeView.attributedText = CodeBlockMetrics.attributed(code, style: style)
            appliedCode = applied
        }
        codeSize = CodeBlockMetrics.codeSize(code, style: style)
        headerHeight = CodeBlockMetrics.headerHeight(style: style)
        setNeedsLayout()
    }

    func copyCode() {
        Pasteboard.copy(code)
    }

    /// `TextMessageCell.prepareForReuse`: dismiss any in-progress selection
    /// inside this code block before the cell is recycled for another row.
    func clearSelectionForReuse() {
        codeView.resignFirstResponder()
        codeView.selectedTextRange = nil
    }

    var codeScrollFrame: CGRect { scrollView.frame }
    var codeViewForTesting: UITextView { codeView }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pad = CodeBlockMetrics.codePadding
        copyButton.frame = CGRect(x: bounds.width - headerHeight, y: 0, width: headerHeight, height: headerHeight)
        languageLabel.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - headerHeight - 8), height: headerHeight)
        let top = headerHeight + CodeBlockMetrics.headerSpacing
        scrollView.frame = CGRect(x: 0, y: top, width: bounds.width, height: codeSize.height + 2 * pad)
        codeView.frame = CGRect(x: pad, y: pad, width: codeSize.width, height: codeSize.height)
        scrollView.contentSize = CGSize(width: codeSize.width + 2 * pad, height: scrollView.frame.height)
    }
}

/// A markdown table as a SwiftUI grid (iOS has no `NSTextTable`) — the Mac
/// table chrome: hairline borders, 4pt cell padding, a 5% label tint on the
/// header row, 8pt bottom margin. Cell text keeps its inline fonts, colours
/// and links; links route through `TimelineLinkRouter`.
struct MarkdownTableGrid: View {
    let table: MarkdownTable
    let router: TimelineLinkRouter

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(table.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        Text(Self.attributed(cell(row, column)))
                            .padding(4)
                            .frame(maxWidth: .infinity, alignment: alignment(column))
                            .background(row == 0 ? Color.primary.opacity(0.05) : Color.clear)
                            .border(Color(uiColor: .separator), width: 0.5)
                    }
                }
            }
        }
        .padding(.bottom, 8)
        .environment(\.openURL, OpenURLAction { url in
            // SwiftUI calls openURL handlers on the main thread.
            MainActor.assumeIsolated { router.route(url) }
            return .handled
        })
    }

    private func cell(_ row: Int, _ column: Int) -> NSAttributedString {
        column < table.rows[row].count ? table.rows[row][column] : NSAttributedString()
    }

    private func alignment(_ column: Int) -> Alignment {
        guard column < table.alignments.count else { return .leading }
        switch table.alignments[column] {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    /// UIKit-attributed cell text → SwiftUI-attributed text (font, colour,
    /// link + underline, strikethrough).
    static func attributed(_ source: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        let text = source.string as NSString
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            var run = AttributedString(text.substring(with: range))
            if let font = attributes[.font] as? UIFont { run.font = Font(font as CTFont) }
            if let color = attributes[.foregroundColor] as? UIColor { run.foregroundColor = Color(uiColor: color) }
            if let link = attributes[.link] as? URL {
                run.link = link
                run.underlineStyle = Text.LineStyle.single
            }
            if attributes[.strikethroughStyle] != nil { run.strikethroughStyle = Text.LineStyle.single }
            result.append(run)
        }
        return result
    }
}

/// UIKit twin of `SenderAvatar`: initials on the sender's box tint.
final class SenderAvatarView: UILabel {
    func configure(name: String) {
        text = SenderAvatar.initials(for: name)
        font = .systemFont(ofSize: 11, weight: .semibold)
        textAlignment = .center
        textColor = UIColor(BoxChip.contrastingForeground(for: name))
        backgroundColor = UIColor(BoxChip.tint(for: name))
        layer.cornerRadius = TextBubbleGeometry.avatarDiameter / 2
        layer.masksToBounds = true
        // The sender is already the text view's accessibility label.
        isAccessibilityElement = false
    }
}

/// UIKit twin of `SendStateIndicator`, right-aligned under an own bubble.
final class SendStateView: UIButton {
    private var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentHorizontalAlignment = .trailing
        addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(state: SendStateGlyph, font: UIFont, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        let symbol: String, title: String, color: UIColor, tappable: Bool, label: String
        switch state {
        case .sent:
            isHidden = true
            return
        case .sending:
            (symbol, title, color, tappable, label) = ("clock", "Sending…", .secondaryLabel, false, "Sending")
        case .queued:
            (symbol, title, color, tappable, label) = ("clock.arrow.circlepath", "Waiting to send — will retry when online",
                                                      .secondaryLabel, true,
                                                      "Queued. Will send when online. Tap to try now.")
        case .failed(let reason):
            (symbol, title, color, tappable, label) = ("exclamationmark.circle", "Failed — tap to retry", .systemRed,
                                                      true, "Send failed: \(reason). Tap to retry.")
        }
        isHidden = false
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.imagePadding = 4
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: font)
        configuration.title = title
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }
        configuration.baseForegroundColor = color
        self.configuration = configuration
        isUserInteractionEnabled = tappable
        accessibilityLabel = label
    }
}
