import SwiftUI

/// Public design-system primitive for a fenced code block: monospaced source
/// in a horizontally scrollable container, with a language label and a copy
/// button. Used by `MarkdownText` (via `Theme.matron.codeBlock`) and is also
/// reused outside the markdown bridge — `EventSourceSheet` and Phase-5
/// `ToolCallCard` import it directly.
public struct CodeBlock: View {
    public let language: String
    public let source: String

    public init(language: String, source: String) {
        self.language = language
        self.source = source
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Pasteboard.copy(source)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(source)
                    .font(.system(.callout, design: .monospaced))
                    .padding(8)
            }
            // SwiftUI's horizontal ScrollView rubber-bands even when the
            // content FITS — a full-width block then springs sideways under
            // a stray drag, which reads as the whole timeline wiggling
            // (observed on iPhone, 2026-07-15). `basedOnSize` restricts the
            // bounce to blocks that actually scroll. The `axes` argument is
            // load-bearing: it defaults to `.vertical`.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background(Color.matronCodeBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
