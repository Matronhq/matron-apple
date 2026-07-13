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
        Markdown(Self.content(for: raw))
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

    /// Parsed-markdown memo. `Markdown(String)` re-parses the source (cmark
    /// under the hood) every time `body` evaluates — for a chat timeline
    /// that means every message re-parses on every scroll-driven re-render.
    /// Messages are immutable, so parse once and key on the raw source.
    /// `NSCache` is thread-safe and evicts under memory pressure; the count
    /// limit keeps a long streaming session (whose intermediate texts churn
    /// through here) from pinning hundreds of stale entries.
    private static let contentCache: NSCache<NSString, ParsedMarkdown> = {
        let cache = NSCache<NSString, ParsedMarkdown>()
        cache.countLimit = 400
        return cache
    }()

    /// `internal` so unit tests can verify the memo hit path.
    static func content(for raw: String) -> MarkdownContent {
        let key = raw as NSString
        if let cached = contentCache.object(forKey: key) {
            return cached.content
        }
        let parsed = MarkdownContent(raw)
        contentCache.setObject(ParsedMarkdown(parsed), forKey: key)
        return parsed
    }

    /// Class box because `NSCache` values must be objects.
    private final class ParsedMarkdown {
        let content: MarkdownContent
        init(_ content: MarkdownContent) { self.content = content }
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

    /// Chat-message variant of `.matron`: same chrome, larger body text.
    /// Scoped to messages so tool-call cards / other markdown keep the
    /// base size. Pair with a small `lineSpacing` on `MarkdownText` for the
    /// roomier line height.
    ///
    /// The scale differs per platform because the system body size does:
    /// iOS body is 17pt (×1.18 ≈ 20pt), macOS body is only 13pt — the
    /// same multiplier read tiny on a desktop display, so the Mac scale
    /// lands message text at ≈ 17.4pt to match matron-web's chat body.
    static let matronMessage: Theme = {
        #if os(macOS)
        let messageScale = 1.34   // 13pt base ≈ 17.4pt messages
        #else
        let messageScale = 1.18   // 17pt base ≈ 20pt messages
        #endif
        return matron
            .text {
                FontFamily(.system(.default))
                ForegroundColor(.primary)
                FontSize(.em(messageScale))
            }
    }()
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
