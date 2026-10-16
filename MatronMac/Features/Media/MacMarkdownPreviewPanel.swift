import SwiftUI
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// The Mac's markdown attachment preview (shared spec "markdown preview"):
/// a trailing side panel in the window, beside whatever the detail column
/// shows, so the conversation or item stays usable next to it. One per
/// window — opening another `.md` file replaces what it shows. Closes with
/// its close button or Esc.
struct MacMarkdownPreviewPanel: View {
    @Bindable var model: MarkdownPreviewModel

    var body: some View {
        if let request = model.request {
            MarkdownPreviewView(
                name: request.name,
                phase: model.phase,
                showsSource: $model.showsSource,
                shareURL: model.shareURL,
                onRetry: { model.retry() },
                onDownload: model.download,
                closesOnEscape: model.closesOnEscape,
                onClose: { model.close() }
            )
            // A new file starts at the top, not at the old one's offset.
            .id(request.id)
        } else {
            Color.clear
        }
    }
}

/// Hangs the window's markdown side panel off the detail column, at the
/// column's trailing edge. Split out of `MacChatListView` to keep its
/// `splitView` expression inside the type-checker budget.
///
/// Laid out by hand rather than with SwiftUI's `.inspector`: inside the
/// window's `NavigationSplitView` the inspector's own split view took the
/// detail content's IDEAL width as its minimum and counted the floating
/// sidebar's width in it as well, so even with the panel closed the window
/// laid its content out wider than itself, and a narrow window spilled the
/// list off the left edge and the detail off the right. On the split view
/// itself it looped AppKit's constraint passes. Here the panel only ever
/// takes what the column has: beside the content while both fit, over it
/// (one pane, the content still mounted underneath) when they don't.
struct MacMarkdownPreviewInspector: ViewModifier {
    let model: MarkdownPreviewModel
    /// The panel's width while it sits beside the content; dragged with the
    /// divider, kept for the window's lifetime.
    @State private var panelWidth = MacMarkdownPanelLayout.idealPanelWidth
    @State private var dragStart: CGFloat?

    func body(content: Content) -> some View {
        // Read here, in `body`, so Observation re-runs this modifier when a
        // file opens or the panel closes.
        let isOpen = model.isOpen
        GeometryReader { geo in
            let layout = MacMarkdownPanelLayout(total: geo.size.width, isOpen: isOpen, preferred: panelWidth)
            HStack(spacing: 0) {
                content
                    // The title-bar header sits at the window's trailing
                    // edge; this keeps it over the content, not the panel.
                    .environment(\.macHeaderTrailingInset, layout.besidePanelWidth.map { $0 + 1 } ?? 0)
                    .frame(width: layout.contentWidth)
                if let width = layout.besidePanelWidth {
                    divider(total: geo.size.width)
                    MacMarkdownPreviewPanel(model: model)
                        .frame(width: width)
                        .background(.background)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .overlay {
                if layout.coversContent {
                    MacMarkdownPreviewPanel(model: model)
                        .background(.background)
                }
            }
        }
    }

    /// A 1 pt line with a wider grab area for resizing the panel.
    private func divider(total: CGFloat) -> some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    // The system's own cursor, not a hand push/pop: the
                    // divider goes away mid-hover when the panel switches
                    // to covering the content, and a pushed cursor would
                    // stay stuck.
                    .pointerStyle(.columnResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStart ?? panelWidth
                            if dragStart == nil { dragStart = start }
                            panelWidth = MacMarkdownPanelLayout.clampedPanelWidth(
                                start - value.translation.width, total: total)
                        }
                        .onEnded { _ in dragStart = nil })
            }
    }
}

/// Where the markdown panel goes in a detail column `total` points wide.
/// Pure, so the narrow-window rules are pinned by unit tests.
struct MacMarkdownPanelLayout: Equatable {
    static let minPanelWidth: CGFloat = 320
    static let idealPanelWidth: CGFloat = 480
    static let maxPanelWidth: CGFloat = 900
    /// The narrowest the conversation or item keeps beside the panel;
    /// below that the panel covers it instead of squeezing it.
    static let minContentWidth: CGFloat = 360

    /// The content's width (the whole column unless the panel sits beside it).
    let contentWidth: CGFloat
    /// The panel's width when it sits beside the content, `nil` otherwise.
    let besidePanelWidth: CGFloat?
    /// The panel is open but the column is too narrow for both: it covers
    /// the content instead.
    let coversContent: Bool

    init(total: CGFloat, isOpen: Bool, preferred: CGFloat) {
        let total = max(0, total)
        guard isOpen else {
            self.init(contentWidth: total, besidePanelWidth: nil, coversContent: false)
            return
        }
        guard total - 1 >= Self.minContentWidth + Self.minPanelWidth else {
            self.init(contentWidth: total, besidePanelWidth: nil, coversContent: true)
            return
        }
        let panel = Self.clampedPanelWidth(preferred, total: total)
        self.init(contentWidth: total - 1 - panel, besidePanelWidth: panel, coversContent: false)
    }

    init(contentWidth: CGFloat, besidePanelWidth: CGFloat?, coversContent: Bool) {
        self.contentWidth = contentWidth
        self.besidePanelWidth = besidePanelWidth
        self.coversContent = coversContent
    }

    /// `width` held to the panel's range and to what leaves the content its
    /// minimum (the 1 pt divider included).
    static func clampedPanelWidth(_ width: CGFloat, total: CGFloat) -> CGFloat {
        let upper = max(minPanelWidth, min(maxPanelWidth, total - 1 - minContentWidth))
        return min(max(width, minPanelWidth), upper)
    }
}

extension EnvironmentValues {
    /// How far from the window's trailing edge the title-bar header should
    /// end: the width of a panel drawn beside the detail content.
    @Entry var macHeaderTrailingInset: CGFloat = 0
}

/// Registers a view that binds Esc itself while `holds` is true (the
/// chat's search bar), so the window's markdown panel gives Esc up
/// meanwhile instead of competing for it.
struct MacMarkdownPreviewEscapeHolder: ViewModifier {
    let holder: String
    let holds: Bool
    @Environment(MarkdownPreviewModel.self) private var markdownPreview: MarkdownPreviewModel?

    func body(content: Content) -> some View {
        content
            .onChange(of: holds, initial: true) { _, holds in
                markdownPreview?.holdEscape(holder, holds)
            }
            .onDisappear { markdownPreview?.holdEscape(holder, false) }
    }
}
