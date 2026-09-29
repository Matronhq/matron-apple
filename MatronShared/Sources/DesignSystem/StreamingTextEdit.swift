#if os(macOS)
import AppKit

/// The smallest paragraph-aligned edit that turns one render of a growing
/// message into the next, so a text storage (a live text view's, or a
/// measuring TextKit stack's) keeps — and does not re-lay out — the
/// paragraphs a streaming delta left alone.
///
/// Exact by construction: `[0, P)` is identical in both strings, characters
/// AND attributes, so replacing `[P, old.length)` with `new[P...]` leaves
/// the storage exactly as a full `setAttributedString(new)` would (a storage
/// fixes attributes as it processes an edit — the render's attribute-less
/// paragraph separators gain a font and their paragraph's style — so
/// neither path leaves it `isEqual` to `new` itself; the fixing runs over
/// whole paragraphs, and `[0, P)` holds whole paragraphs).
///
/// Markdown can restyle text it already emitted. Any restyle of an earlier
/// paragraph is an attribute difference there and moves `P` back to that
/// paragraph's start. Measured on the chat renderer (2026-09-29), the
/// common cases never reach back: a setext underline restyles only the
/// paragraph directly above it (the last one), tight and loose lists
/// render alike, and a fence only restyles what follows it. A table does:
/// every build makes new `NSTextBlock`s, which compare by identity, so a
/// growing table differs from its first cell on.
///
/// The message body only applies this to bodies without tables (a TextKit
/// 2 view cannot lay a table out anyway); the streaming measurer (TextKit
/// 1) applies it to any body, and a table just resets `P` to its start.
public enum StreamingTextEdit {
    /// `P`: the start of the paragraph holding the first difference between
    /// `old` and `new` — in characters (the common UTF-16 prefix) or, before
    /// that, in attributes. Always a paragraph start in both strings, and
    /// `0 ≤ P ≤ min(old.length, new.length)`. `0` means nothing is reusable.
    public static func stablePrefix(old: NSAttributedString, new: NSAttributedString) -> Int {
        let oldText = old.string as NSString
        let newText = new.string as NSString
        let common = commonPrefixLength(oldText, newText)
        // The paragraph holding the first changed character is re-laid out
        // whole. The prefix before `common` is shared, so both strings agree
        // on where that paragraph starts; `min` is belt and braces.
        let paragraphStart = min(oldText.paragraphRange(for: NSRange(location: common, length: 0)).location,
                                 newText.paragraphRange(for: NSRange(location: common, length: 0)).location)
        guard paragraphStart > 0,
              let difference = firstAttributeDifference(old, new, before: paragraphStart) else {
            return paragraphStart
        }
        return newText.paragraphRange(for: NSRange(location: difference, length: 0)).location
    }

    /// Leaves `storage` as `setAttributedString(new)` would, given that it
    /// currently holds `old` (as written by that same call). Replaces from
    /// `stablePrefix(old:new:)` inside one editing transaction, or the
    /// whole string when that is `0`.
    ///
    /// - Returns: the location the edit started at (`0` = full replace).
    @discardableResult
    public static func apply(from old: NSAttributedString, to new: NSAttributedString,
                             in storage: NSTextStorage) -> Int {
        let location = stablePrefix(old: old, new: new)
        guard location > 0 else {
            storage.setAttributedString(new)
            return 0
        }
        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: location, length: storage.length - location),
            with: new.attributedSubstring(from: NSRange(location: location, length: new.length - location)))
        storage.endEditing()
        return location
    }

    /// Length of the common UTF-16 prefix, compared a chunk at a time (one
    /// bridged call per chunk, not per character).
    static func commonPrefixLength(_ a: NSString, _ b: NSString) -> Int {
        let count = min(a.length, b.length)
        let chunk = 1024
        var left = [unichar](repeating: 0, count: chunk)
        var right = [unichar](repeating: 0, count: chunk)
        var offset = 0
        while offset < count {
            let length = min(chunk, count - offset)
            a.getCharacters(&left, range: NSRange(location: offset, length: length))
            b.getCharacters(&right, range: NSRange(location: offset, length: length))
            for index in 0..<length where left[index] != right[index] {
                return offset + index
            }
            offset += length
        }
        return count
    }

    /// The first location in `[0, end)` whose attributes differ between the
    /// two strings (their characters there are equal), or nil. Walks runs:
    /// attributes are constant over each effective range, so only run
    /// starts need comparing. Run boundaries of equal attributes may still
    /// fall differently in two independently built strings, hence stepping
    /// to the nearer boundary rather than assuming they line up.
    static func firstAttributeDifference(_ old: NSAttributedString, _ new: NSAttributedString,
                                         before end: Int) -> Int? {
        var location = 0
        while location < end {
            var oldRun = NSRange()
            var newRun = NSRange()
            let oldAttributes = old.attributes(at: location, effectiveRange: &oldRun)
            let newAttributes = new.attributes(at: location, effectiveRange: &newRun)
            if !(oldAttributes as NSDictionary).isEqual(to: newAttributes) { return location }
            location = min(NSMaxRange(oldRun), NSMaxRange(newRun))
        }
        return nil
    }
}
#endif
