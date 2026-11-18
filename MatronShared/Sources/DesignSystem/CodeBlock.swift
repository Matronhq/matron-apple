import SwiftUI

/// Public design-system primitive for a fenced code block: monospaced source
/// in a horizontally scrollable container, with a language label and a copy
/// button. Used by `MarkdownText` (via `Theme.matron.codeBlock`) and is also
/// reused outside the markdown bridge — the Phase-5 `ToolCallCard` imports
/// it directly.
///
/// `language` is the fence's whole info string. Its first word is the
/// language shown in the label; a later word `collapsed` folds the block
/// behind a Show button (the copy button still copies it). The bridge uses
/// this for the exact JSON input on an "Allow once" ask, which the item
/// already describes in plain words above it.
public struct CodeBlock: View {
    public let language: String
    public let source: String
    @State private var expanded = false

    public init(language: String, source: String) {
        self.language = language
        self.source = source
    }

    /// The fence info string, split into the language and whether the block
    /// starts folded.
    struct FenceInfo: Equatable {
        let language: String
        let collapsed: Bool

        init(_ info: String) {
            let words = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            language = words.first ?? ""
            collapsed = words.dropFirst().contains("collapsed")
        }
    }

    public var body: some View {
        let info = FenceInfo(language)
        let shown = !info.collapsed || expanded
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if info.collapsed {
                    Button {
                        expanded.toggle()
                    } label: {
                        Label(expanded ? "Hide \(info.language.isEmpty ? "code" : info.language)"
                                       : "Show \(info.language.isEmpty ? "code" : info.language)",
                              systemImage: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint(expanded ? "Hides the block" : "Shows the block")
                } else {
                    Text(info.language.isEmpty ? "code" : info.language)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Pasteboard.copy(source)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                        #if os(iOS)
                        // The icon is far smaller than a finger: widen the
                        // hit area without moving anything.
                        .padding(14)
                        .contentShape(Rectangle())
                        .padding(-14)
                        #endif
                }
            }
            if shown {
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
}
