import Foundation

/// Splits a leading "glyph" (a single non-alphanumeric character — an emoji
/// or symbol such as ✕, ⚡, ✓, 👍) off the front of a choice/answer label so
/// callers can render it in a fixed-width slot and keep the following text
/// aligned across a stack of buttons regardless of how wide each glyph is.
///
/// A glyph is recognised only when the label starts with exactly one
/// non-alphanumeric `Character` (a grapheme cluster, so a multi-scalar emoji
/// counts as one) that is immediately followed by whitespace. Otherwise the
/// whole label comes back as `text` with `glyph` nil — this covers a plain
/// label ("Other action"), a label whose first character is alphanumeric
/// ("1 apple"), a glyph with no trailing space ("⚡Send"), and a label that is
/// nothing but a glyph ("⚡").
///
/// Pure and internal so the design-system snapshot bundle can unit-test it
/// directly via `@testable import`.
func splitLeadingGlyph(_ label: String) -> (glyph: String?, text: String) {
    guard let first = label.first,
          !first.isWhitespace,
          !(first.isLetter || first.isNumber) else {
        return (nil, label)
    }
    let rest = label.dropFirst()
    guard let next = rest.first, next.isWhitespace else {
        return (nil, label)
    }
    let text = String(rest.drop(while: { $0.isWhitespace }))
    guard !text.isEmpty else {
        return (nil, label)
    }
    return (String(first), text)
}
