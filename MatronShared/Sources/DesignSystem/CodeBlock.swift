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
            .background(Color.matronCodeBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
