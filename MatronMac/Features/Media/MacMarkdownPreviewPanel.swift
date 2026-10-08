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

/// Hangs the window's markdown side panel off the detail column as an
/// inspector. Split out of `MacChatListView` to keep its `splitView`
/// expression inside the type-checker budget.
struct MacMarkdownPreviewInspector: ViewModifier {
    let model: MarkdownPreviewModel

    func body(content: Content) -> some View {
        // Read here, in `body`, so Observation re-runs this modifier when a
        // file opens or the panel closes; a read only inside the binding's
        // getter happens outside body tracking.
        let isOpen = model.isOpen
        content.inspector(isPresented: Binding(
            get: { isOpen },
            set: { if !$0 { model.close() } }
        )) {
            MacMarkdownPreviewPanel(model: model)
                .inspectorColumnWidth(min: 320, ideal: 480, max: 900)
        }
    }
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
