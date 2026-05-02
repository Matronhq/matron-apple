import SwiftUI
import MarkdownUI

/// Renders Markdown source as a SwiftUI view using the `matron` theme. Wraps
/// `MarkdownUI`'s `Markdown` view with a copyable, code-block-aware theme so
/// callers don't have to reach for `markdownTheme(_:)` themselves.
public struct MarkdownText: View {
    let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public var body: some View {
        Markdown(raw)
            .markdownTheme(.matron)
            .textSelection(.enabled)
    }
}

public extension Theme {
    /// Matron's house markdown theme: system font, monospaced inline code on a
    /// subtle grey, accent-coloured underlined links, and a custom code-block
    /// renderer with a copy button (see `CodeBlockView` below).
    static let matron: Theme = Theme()
        .text {
            FontFamily(.system(.default))
            ForegroundColor(.primary)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(.matronInlineCodeBg)
        }
        .codeBlock { configuration in
            CodeBlockView(language: configuration.language ?? "", source: configuration.content)
        }
        .link {
            ForegroundColor(.accentColor)
            UnderlineStyle(.single)
        }
}

/// In-house renderer used by `Theme.matron.codeBlock`. Task 2b promotes the
/// public `CodeBlock` primitive; this private view is the bridge between
/// MarkdownUI's `CodeBlockConfiguration` and that primitive's plain init.
private struct CodeBlockView: View {
    let language: String
    let source: String

    var body: some View {
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

/// Cross-platform pasteboard wrapper. Lives in DesignSystem so primitives compile
/// for both iOS and macOS without `#if` scattered through their bodies.
enum Pasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit) && !os(macOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

extension Color {
    #if canImport(UIKit) && !os(macOS)
    static let matronInlineCodeBg = Color(.systemGray6)
    static let matronCodeBg = Color(.systemGray6)
    #elseif os(macOS)
    static let matronInlineCodeBg = Color(nsColor: .controlBackgroundColor)
    static let matronCodeBg = Color(nsColor: .controlBackgroundColor)
    #endif
}
