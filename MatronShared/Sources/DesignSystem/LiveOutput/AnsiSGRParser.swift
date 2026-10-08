import SwiftUI

/// Stateful ANSI → `AttributedString` converter for the live-output pane.
/// Mirrors matron-web's `ansiToReact`: SGR color/bold codes are applied,
/// every other escape sequence (cursor movement, OSC titles, …) is
/// stripped. Stateful on two axes so it can be fed streaming chunks:
///   * SGR state (current color/bold) carries across chunks;
///   * a chunk may end mid-escape-sequence — the tail is buffered and
///     prepended to the next chunk instead of leaking `ESC[3` fragments
///     into the output.
public struct AnsiSGRParser {
    /// Terminal palette tuned for the pane's pinned dark background.
    /// Indexes 0–7 normal, 8–15 bright (SGR 30–37 / 90–97).
    static let palette: [Color] = [
        Color(red: 0.20, green: 0.20, blue: 0.20), // black
        Color(red: 0.90, green: 0.35, blue: 0.35), // red
        Color(red: 0.45, green: 0.82, blue: 0.45), // green
        Color(red: 0.88, green: 0.79, blue: 0.36), // yellow
        Color(red: 0.42, green: 0.63, blue: 0.94), // blue
        Color(red: 0.80, green: 0.52, blue: 0.86), // magenta
        Color(red: 0.40, green: 0.80, blue: 0.83), // cyan
        Color(red: 0.86, green: 0.86, blue: 0.86), // white
        Color(red: 0.45, green: 0.45, blue: 0.45),
        Color(red: 1.00, green: 0.47, blue: 0.47),
        Color(red: 0.56, green: 0.94, blue: 0.56),
        Color(red: 0.98, green: 0.91, blue: 0.50),
        Color(red: 0.55, green: 0.73, blue: 1.00),
        Color(red: 0.92, green: 0.64, blue: 0.98),
        Color(red: 0.52, green: 0.93, blue: 0.96),
        Color(red: 0.98, green: 0.98, blue: 0.98),
    ]

    private var pendingEscape = ""
    private var bold = false
    private var foreground: Color?

    public init() {}

    /// Converts one streamed chunk, applying carried-over SGR state and
    /// buffering any trailing partial escape sequence for the next call.
    public mutating func append(_ chunk: String) -> AttributedString {
        var result = AttributedString()
        var plain = ""
        let text = pendingEscape + chunk
        pendingEscape = ""
        var index = text.startIndex

        func flushPlain() {
            guard !plain.isEmpty else { return }
            var run = AttributedString(plain)
            if let foreground { run.foregroundColor = foreground }
            if bold { run.inlinePresentationIntent = .stronglyEmphasized }
            result += run
            plain = ""
        }

        while index < text.endIndex {
            let char = text[index]
            guard char == "\u{1B}" else {
                plain.append(char)
                index = text.index(after: index)
                continue
            }
            // At an ESC: emit what's accumulated under the CURRENT
            // attributes before any SGR change mutates them.
            flushPlain()
            // If the rest of the chunk can't tell us what kind of
            // sequence this is yet, buffer it for the next chunk.
            guard let kindIndex = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
                  kindIndex < text.endIndex else {
                pendingEscape = String(text[index...])
                break
            }
            switch text[kindIndex] {
            case "[": // CSI … final byte 0x40–0x7E
                var scan = text.index(after: kindIndex)
                var params = ""
                var terminated = false
                while scan < text.endIndex {
                    let c = text[scan]
                    if let ascii = c.asciiValue, (0x40...0x7E).contains(ascii) {
                        if c == "m" { applySGR(params) } // others stripped
                        index = text.index(after: scan)
                        terminated = true
                        break
                    }
                    params.append(c)
                    scan = text.index(after: scan)
                }
                if !terminated {
                    pendingEscape = String(text[index...])
                    index = text.endIndex
                }
            case "]": // OSC … terminated by BEL or ESC \
                var scan = text.index(after: kindIndex)
                var terminated = false
                while scan < text.endIndex {
                    if text[scan] == "\u{07}" {
                        index = text.index(after: scan)
                        terminated = true
                        break
                    }
                    if text[scan] == "\u{1B}",
                       let next = text.index(scan, offsetBy: 1, limitedBy: text.endIndex),
                       next < text.endIndex, text[next] == "\\" {
                        index = text.index(after: next)
                        terminated = true
                        break
                    }
                    scan = text.index(after: scan)
                }
                if !terminated {
                    // Unterminated OSC (e.g. a title split across chunks)
                    // could buffer unboundedly on hostile input — cap what
                    // we're willing to carry and otherwise drop it.
                    let tail = String(text[index...])
                    pendingEscape = tail.count <= 512 ? tail : ""
                    index = text.endIndex
                }
            default:
                // Two-byte escape (ESC + one char) — strip both.
                index = text.index(after: kindIndex)
            }
        }
        flushPlain()
        return result
    }

    private mutating func applySGR(_ params: String) {
        let codes = params.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        var i = 0
        let list = codes.isEmpty ? [0] : codes
        while i < list.count {
            let code = list[i]
            switch code {
            case 0: bold = false; foreground = nil
            case 1: bold = true
            case 22: bold = false
            case 30...37: foreground = Self.palette[code - 30]
            case 90...97: foreground = Self.palette[code - 90 + 8]
            case 39: foreground = nil
            case 38:
                // 38;5;n (256-color) or 38;2;r;g;b (truecolor).
                if i + 2 < list.count && list[i + 1] == 5 {
                    foreground = Self.color256(list[i + 2])
                    i += 2
                } else if i + 4 < list.count && list[i + 1] == 2 {
                    foreground = Color(red: Double(list[i + 2]) / 255,
                                       green: Double(list[i + 3]) / 255,
                                       blue: Double(list[i + 4]) / 255)
                    i += 4
                }
            default:
                break // backgrounds, underline, etc. — stripped
            }
            i += 1
        }
    }

    static func color256(_ n: Int) -> Color? {
        switch n {
        case 0...15:
            return palette[n]
        case 16...231:
            let v = n - 16
            let r = v / 36, g = (v % 36) / 6, b = v % 6
            let scale = { (c: Int) in c == 0 ? 0.0 : (Double(c) * 40 + 55) / 255 }
            return Color(red: scale(r), green: scale(g), blue: scale(b))
        case 232...255:
            let gray = (Double(n - 232) * 10 + 8) / 255
            return Color(red: gray, green: gray, blue: gray)
        default:
            return nil
        }
    }
}
