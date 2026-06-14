import SwiftUI
import os
import MarkdownUI

/// Renders Markdown source as a SwiftUI view using the `matron` theme. Wraps
/// `MarkdownUI`'s `Markdown` view with a copyable, code-block-aware theme so
/// callers don't have to reach for `markdownTheme(_:)` themselves.
///
/// Link handling policy (QA finding #11):
///   - `http(s)` URLs fall through to the system handler so the OS picks the
///     user's preferred browser / in-app handler.
///   - Matrix-internal schemes (`matrix:` permalinks, `mxc:` content URIs)
///     are swallowed for now and logged at `.debug`. Phase 3 wires
///     permalink resolution; until then we'd rather no-op than have the OS
///     surface a "no app to handle this URL" error sheet to the user.
public struct MarkdownText: View {
    let raw: String
    let theme: Theme
    let lineSpacing: CGFloat

    /// - Parameters:
    ///   - theme: markdown theme. Defaults to `.matron`; chat messages pass
    ///     `.matronMessage` for a slightly larger body size.
    ///   - lineSpacing: extra spacing between wrapped lines. Defaults to `0`;
    ///     chat messages pass a small value for more comfortable line height.
    public init(_ raw: String, theme: Theme = .matron, lineSpacing: CGFloat = 0) {
        self.raw = raw
        self.theme = theme
        self.lineSpacing = lineSpacing
    }

    public var body: some View {
        Markdown(raw)
            .markdownTheme(theme)
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                Self.handle(url: url)
            })
    }

    /// Routes a URL tap to the system handler or a no-op based on scheme.
    /// `internal` so unit tests can exercise the policy without rendering
    /// the SwiftUI view.
    static func handle(url: URL) -> OpenURLAction.Result {
        switch url.scheme?.lowercased() {
        case "http", "https":
            // Defer to the system handler (browser, deep-link app).
            return .systemAction
        case "matrix", "mxc":
            // Swallow until Phase 3 lands permalink + content-URI handling.
            // `.handled` keeps the OS from surfacing a "no handler" error.
            Self.log.debug("Suppressed in-app open for matrix-internal URL: \(url.absoluteString, privacy: .public)")
            return .handled
        default:
            // Unknown scheme — fall through to the system so the user
            // still gets the OS's "no handler" sheet rather than a
            // silent drop. Aligns with default `OpenURLAction` behaviour.
            return .systemAction
        }
    }

    private static let log = Logger(subsystem: "chat.matron", category: "MarkdownText")
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

    /// Chat-message variant of `.matron`: same chrome, one step larger body
    /// text. Scoped to messages so tool-call cards / other markdown keep the
    /// base size. Pair with a small `lineSpacing` on `MarkdownText` for the
    /// roomier line height.
    static let matronMessage: Theme = matron
        .text {
            FontFamily(.system(.default))
            ForegroundColor(.primary)
            FontSize(.em(1.0625))
        }
}

/// Cross-platform pasteboard wrapper. Lives in DesignSystem so primitives compile
/// for both iOS and macOS without `#if` scattered through their bodies.
/// Promoted to `public` in Phase 2 so app-target views (`MacChatView`'s
/// right-click context-menu Copy action) can reach it without re-implementing
/// the `#if` cascade themselves.
public enum Pasteboard {
    public static func copy(_ string: String) {
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
