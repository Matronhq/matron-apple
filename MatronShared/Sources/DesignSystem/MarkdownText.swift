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
    /// subtle grey, accent-coloured underlined links, and the public
    /// `CodeBlock` primitive (with a copy button) wired in for fenced blocks.
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
            CodeBlock(language: configuration.language ?? "", source: configuration.content)
        }
        .link {
            ForegroundColor(.accentColor)
            UnderlineStyle(.single)
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
