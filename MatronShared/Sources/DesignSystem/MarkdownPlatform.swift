#if os(macOS)
import AppKit

/// Platform types for `MarkdownAttributed` — one renderer source, AppKit on
/// the Mac (unchanged output, pinned by `MarkdownAttributedFingerprintTests`)
/// and UIKit on iOS (the UIKit chat timeline, spec 2026-09-26).
typealias MarkdownFont = NSFont
typealias MarkdownColor = NSColor

enum MarkdownPalette {
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var accent: NSColor { .controlAccentColor }
    static var codeBackground: NSColor { .controlBackgroundColor }
}

enum MarkdownPlatform {
    /// System font for body text, monospaced system font for code, traits
    /// via symbolic traits so the descriptor reliably reports bold/italic.
    static func font(size: CGFloat, bold: Bool, italic: Bool, monospaced: Bool) -> NSFont {
        let base: NSFont = monospaced
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}
#else
import UIKit

typealias MarkdownFont = UIFont
typealias MarkdownColor = UIColor

enum MarkdownPalette {
    static var label: UIColor { .label }
    static var secondaryLabel: UIColor { .secondaryLabel }
    /// `Color.accentColor` on iOS is the system tint — MarkdownUI's link colour.
    static var accent: UIColor { .tintColor }
    /// `Color.matronInlineCodeBg` / `.matronCodeBg` on iOS.
    static var codeBackground: UIColor { .systemGray6 }
}

enum MarkdownPlatform {
    static func font(size: CGFloat, bold: Bool, italic: Bool, monospaced: Bool) -> UIFont {
        let base: UIFont = monospaced
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty, let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
#endif
