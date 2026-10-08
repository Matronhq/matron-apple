import SwiftUI
import UniformTypeIdentifiers
import MarkdownUI
import MatronModels

/// The markdown attachment preview (shared spec "markdown preview"): a
/// header with the file name and Source / Copy / Share / Save, over the
/// file rendered with the app's own markdown renderer at the tracker's
/// reading size — or its raw text in monospace. The Mac shows it in a
/// trailing side panel, the iPhone in a full-height sheet; both hosts feed
/// it from a `MarkdownPreviewModel`.
public struct MarkdownPreviewView: View {
    let name: String
    let phase: MarkdownPreviewPhase
    @Binding var showsSource: Bool
    let shareURL: URL?
    let onRetry: () -> Void
    /// The host's download/open path; `nil` hides the Download button.
    let onDownload: (() -> Void)?
    let onClose: () -> Void
    /// Whether Esc presses Close. The Mac panel turns it off while another
    /// view in the window owns Esc (`MarkdownPreviewModel.closesOnEscape`).
    let closesOnEscape: Bool

    @State private var isExporting = false

    public init(name: String, phase: MarkdownPreviewPhase, showsSource: Binding<Bool>, shareURL: URL?,
                onRetry: @escaping () -> Void, onDownload: (() -> Void)?, closesOnEscape: Bool = true,
                onClose: @escaping () -> Void) {
        self.name = name
        self.phase = phase
        self._showsSource = showsSource
        self.shareURL = shareURL
        self.onRetry = onRetry
        self.onDownload = onDownload
        self.onClose = onClose
        self.closesOnEscape = closesOnEscape
    }

    private var document: MarkdownPreviewDocument? {
        if case .loaded(let document) = phase { return document }
        return nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        .fileExporter(isPresented: $isExporting,
                      document: document.map { MarkdownFileDocument(text: $0.text) },
                      contentType: MarkdownFileDocument.markdownType,
                      defaultFilename: name) { _ in }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(name)
            Toggle(isOn: $showsSource) {
                Text("Source")
            }
            .toggleStyle(.button)
            .disabled(document == nil)
            .help(showsSource ? "Show the formatted file" : "Show the markdown source")
            Button {
                if let document { Pasteboard.copy(document.text) }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(document == nil)
            .help("Copy the markdown")
            if let shareURL, document != nil {
                ShareLink(item: shareURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Share the file")
            }
            Button {
                isExporting = true
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(document == nil)
            .help("Save the file")
            Button(action: onClose) {
                Label("Close", systemImage: "xmark")
            }
            // Esc closes the panel on the Mac — unless another view in the
            // window has bound it (the chat's search bar).
            .keyboardShortcut(closesOnEscape ? .cancelAction : nil)
            .help("Close")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .loading:
            ProgressView("Loading…")
        case .failed(let failure):
            failureView(failure)
        case .loaded(let document):
            if showsSource {
                source(document)
            } else {
                rendered(document)
            }
        }
    }

    private func rendered(_ document: MarkdownPreviewDocument) -> some View {
        ScrollView {
            renderedBody(document.rendered)
                .frame(maxWidth: ItemTypography.measure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    /// The same renderer and reading scale as a tracker item body. The text
    /// is already `MarkdownPreview.sanitized`: no image in it can load, and
    /// only http(s) and mailto links stay links. The image providers are a
    /// second lock on the same door.
    @ViewBuilder
    private func renderedBody(_ markdown: String) -> some View {
        #if os(macOS)
        SelectableMessageText(markdown, style: .item)
        #else
        MarkdownText(markdown, theme: .matronItem, lineSpacing: ItemTypography.lineSpacing)
            .markdownImageProvider(NoImageProvider())
            .markdownInlineImageProvider(NoInlineImageProvider())
        #endif
    }

    private func source(_ document: MarkdownPreviewDocument) -> some View {
        ScrollView {
            // Chunks of whole lines, laid out lazily: one `Text` for a
            // 2 MB file stalls the main thread.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(document.sourceChunks.enumerated()), id: \.offset) { _, chunk in
                    Text(verbatim: chunk)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    private func failureView(_ failure: MarkdownPreviewFailure) -> some View {
        VStack(spacing: 12) {
            Image(systemName: failure == .expired ? "doc.badge.clock" : "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(Self.message(for: failure))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if failure == .unavailable {
                    Button("Retry", action: onRetry)
                }
                if failure != .expired, let onDownload {
                    Button("Download", action: onDownload)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
    }

    static func message(for failure: MarkdownPreviewFailure) -> String {
        switch failure {
        case .tooLarge: return "This file is too large to preview."
        case .expired: return "This file has expired and is no longer available."
        case .unavailable: return "Couldn’t load this file."
        }
    }
}

/// Block images in a previewed file never load (shared spec: never fetch
/// remote or unauthenticated content).
struct NoImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        EmptyView()
    }
}

/// Inline images in a previewed file never load either.
struct NoInlineImageProvider: InlineImageProvider {
    struct Blocked: Error {}
    func image(with url: URL, label: String) async throws -> Image {
        throw Blocked()
    }
}

/// The previewed file for Save (`fileExporter`): its text as UTF-8.
public struct MarkdownFileDocument: FileDocument {
    /// `net.daringfireball.markdown` where the system knows it, so the save
    /// panel keeps the `.md` name; plain text otherwise.
    public static var markdownType: UTType { UTType("net.daringfireball.markdown") ?? .plainText }
    public static var readableContentTypes: [UTType] { [markdownType, .plainText] }

    public var text: String

    public init(text: String) {
        self.text = text
    }

    public init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
