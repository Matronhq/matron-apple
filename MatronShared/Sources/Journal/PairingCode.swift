import Foundation

/// Pairing-code input helpers. Codes are 8 characters from a no-lookalike
/// alphabet (Crockford base32 minus vowels), displayed by the box as
/// `XXXX-XXXX`. The server normalizes before lookup exactly like
/// `normalize` below, so the app accepts sloppy input (lowercase, spaces,
/// missing hyphen) and never blocks submission on format.
public enum PairingCode {
    public static let length = 8

    /// Server-equivalent normalization: uppercase, strip every
    /// non-alphanumeric character.
    public static func normalize(_ raw: String) -> String {
        String(raw.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Normalized code formatted for display as it's typed: a hyphen after
    /// the fourth character once a fifth exists (`KTNM-3VQ8`; partial input
    /// stays unhyphenated until then).
    public static func display(_ raw: String) -> String {
        let normalized = normalize(raw)
        guard normalized.count > 4 else { return normalized }
        let head = normalized.prefix(4)
        let tail = normalized.dropFirst(4)
        return "\(head)-\(tail)"
    }

    /// Whether the input is worth previewing: exactly 8 normalized chars.
    public static func isPlausible(_ raw: String) -> Bool {
        normalize(raw).count == length
    }
}
