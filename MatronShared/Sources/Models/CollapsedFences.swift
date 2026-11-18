import Foundation

/// Fenced code blocks that start folded, for the native item threads.
///
/// A fence whose info string has a later word `collapsed`
/// (```` ```json collapsed ````) is a block the reader rarely needs: the
/// bridge writes the exact JSON input of an "Allow once" ask this way, under
/// a description of it in plain words. The SwiftUI `CodeBlock` folds such a
/// block itself; the native threads draw markdown as attributed text, so
/// they fold it here, in the source: a folded block becomes one link line
/// ("▸ Show json · Copy"), and an open one keeps its code under a "▾ Hide json"
/// link. The link's URL names the block (`url(for:)`); the thread toggles
/// it in its own set of open blocks and draws the card again, so a toggle is
/// an ordinary content change that measures the row afresh.
///
/// Only top-level fences fold (the line starts with the fence). A fence
/// inside a list or a quote, or one never closed, is left as written.
public enum CollapsedFences {
    /// The scheme of a toggle link. Handled in-app; never handed to the OS.
    public static let scheme = "matron-fold"

    /// One foldable block: its lines in the source and what it shows.
    struct Fence: Equatable {
        /// The block's lines, opening and closing fence included.
        let lines: Range<Int>
        /// The info string's first word ("json"), or "" for none.
        let language: String
        /// The fence as written (a run of backticks or tildes).
        let marker: String
        let code: [Substring]
    }

    /// Whether `source` may have a foldable block: a cheap test that skips
    /// the line scan for nearly every body.
    public static func mayContain(_ source: String) -> Bool {
        source.contains("collapsed")
    }

    /// The id of the `index`th foldable block of the text keyed `key`
    /// (a card part).
    public static func foldID(key: String, index: Int) -> String {
        "\(key)/\(index)"
    }

    /// What a fold link asks for: open or fold the block, or copy its code
    /// (offered while it is folded; an open block has its own copy button).
    public enum Link: Equatable {
        case toggle(String)
        case copy(String)
    }

    /// The toggle link for a block. The id is percent-encoded down to
    /// letters and digits, so no character in it can end the markdown
    /// link or the URL early.
    public static func url(for foldID: String) -> URL { link("toggle", foldID) }

    /// The link that copies a folded block's code.
    public static func copyURL(for foldID: String) -> URL { link("copy", foldID) }

    private static func link(_ action: String, _ foldID: String) -> URL {
        let id = foldID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "\(scheme):\(action)?id=\(id)")!
    }

    /// What a fold link asks for, or `nil` for any other link.
    public static func link(from url: URL) -> Link? {
        guard url.scheme == scheme else { return nil }
        let parts = url.absoluteString.dropFirst(scheme.count + 1).components(separatedBy: "?id=")
        guard parts.count == 2, let id = parts[1].removingPercentEncoding, !id.isEmpty else { return nil }
        switch parts[0] {
        case "toggle": return .toggle(id)
        case "copy": return .copy(id)
        default: return nil
        }
    }

    /// The block a toggle link names, or `nil` for any other link.
    public static func foldID(from url: URL) -> String? {
        if case .toggle(let id)? = link(from: url) { return id }
        return nil
    }

    /// The code of the block `foldID` names in the text keyed `key`, as
    /// written: what its Copy link copies.
    public static func code(of foldID: String, key: String, in source: String) -> String? {
        let prefix = key + "/"
        guard foldID.hasPrefix(prefix), let index = Int(foldID.dropFirst(prefix.count)) else { return nil }
        let blocks = fences(in: source.split(separator: "\n", omittingEmptySubsequences: false))
        guard blocks.indices.contains(index) else { return nil }
        return blocks[index].code.joined(separator: "\n")
    }

    /// `source` as a native thread draws it: each foldable block folded to
    /// its "Show" link, or, when its id is in `expanded`, open under its
    /// "Hide" link. `key` names the text (one per card part). Text without
    /// a foldable block comes back unchanged.
    public static func present(_ source: String, key: String, expanded: Set<String>) -> String {
        guard mayContain(source) else { return source }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let fences = fences(in: lines)
        guard !fences.isEmpty else { return source }
        var out: [String] = []
        var next = 0
        for (index, fence) in fences.enumerated() {
            out += lines[next..<fence.lines.lowerBound].map(String.init)
            let id = foldID(key: key, index: index)
            let name = fence.language.isEmpty ? "code" : fence.language
            let open = expanded.contains(id)
            // A link line is a paragraph of its own: blank lines round it,
            // or it would run on into the text above or below.
            if let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { out.append("") }
            out.append(open ? "[▾ Hide \(name)](\(url(for: id).absoluteString))"
                            : "[▸ Show \(name)](\(url(for: id).absoluteString)) · [Copy](\(copyURL(for: id).absoluteString))")
            if open {
                out.append("")
                out.append(fence.marker + fence.language)
                out += fence.code.map(String.init)
                out.append(fence.marker)
            }
            next = fence.lines.upperBound
            if next < lines.count, !lines[next].trimmingCharacters(in: .whitespaces).isEmpty { out.append("") }
        }
        out += lines[next...].map(String.init)
        return out.joined(separator: "\n")
    }

    /// The foldable blocks of `lines`, in order. Every fence is tracked, so
    /// the word "collapsed" inside another block's code never opens one.
    static func fences(in lines: [Substring]) -> [Fence] {
        var found: [Fence] = []
        var i = 0
        while i < lines.count {
            guard let open = opening(lines[i]) else { i += 1; continue }
            var j = i + 1
            while j < lines.count, !closes(lines[j], open: open.marker) { j += 1 }
            guard j < lines.count else { break } // never closed: left as written
            let words = open.info.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if words.dropFirst().contains("collapsed") {
                found.append(Fence(lines: i..<(j + 1), language: words.first.map(String.init) ?? "",
                                   marker: open.marker, code: Array(lines[(i + 1)..<j])))
            }
            i = j + 1
        }
        return found
    }

    /// A top-level opening fence: three or more backticks or tildes at the
    /// start of the line, then the info string (which, after backticks,
    /// may not hold a backtick).
    private static func opening(_ line: Substring) -> (marker: String, info: Substring)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let marker = line.prefix(while: { $0 == first })
        guard marker.count >= 3 else { return nil }
        let info = line.dropFirst(marker.count)
        if first == "`", info.contains("`") { return nil }
        return (String(marker), info.drop(while: { $0 == " " || $0 == "\t" }))
    }

    /// Whether `line` closes a block opened with `open`: up to three spaces,
    /// at least as long a run of the same character, nothing after but
    /// spaces.
    private static func closes(_ line: Substring, open: String) -> Bool {
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3, let char = open.first else { return false }
        let rest = line.dropFirst(indent.count)
        let run = rest.prefix(while: { $0 == char })
        return run.count >= open.count && rest.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
    }
}
