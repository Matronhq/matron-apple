import CryptoKit
import Foundation

/// Shared attachment temp-file writer (fix wave, item H). Extracted from
/// `ChatViewModel.writeTempFile`/`sanitisedAttachmentFilename` so the
/// items-tracker hosts (attach-a-file/photo on a comment) can reuse the
/// same two hazard mitigations instead of duplicating them:
///
/// - a path-traversal filename from an attacker-controllable sender
///   (Matrix event metadata, a tracker attachment name) must never reach
///   `appendingPathComponent` raw;
/// - two different attachments that happen to share a display filename
///   (routine — "report.pdf" from two different rooms/items) must not
///   clobber each other in a flat temp directory.
public enum AttachmentTempFiles {
    /// Strip path-traversal and directory-separator components from an
    /// attacker-controllable filename. Inputs that reduce to an empty
    /// string (all-`/`, `..`, hidden-only) fall back to a UUID so callers
    /// never pass `/` to `appendingPathComponent` or write a hidden file
    /// by accident.
    public static func sanitisedFilename(_ raw: String) -> String {
        // Last path component drops any leading directory tree the
        // sender embedded — `Foundation.URL`-style normalisation
        // collapses `..` / `.` segments along the way.
        let trimmed = (raw as NSString).lastPathComponent
        // Replace remaining separators (rare, but `:` on macOS
        // historically and `\` on Windows-style senders) with `_`.
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "_")
                              .replacingOccurrences(of: ":", with: "_")
        let stripped = cleaned.trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty || stripped == "." || stripped == ".." {
            return UUID().uuidString
        }
        return stripped
    }

    /// Writes `data` under a per-`blobRef` subdirectory of
    /// `matron-attachments` in the temp directory, so two attachments that
    /// share a display `name` never collide: uniqueness lives in the
    /// parent directory (a digest of `blobRef`), the human-friendly
    /// basename is preserved for share/preview labels. Returns the file
    /// URL written. Files written here are not cleaned up by this call —
    /// callers rely on the OS reaping the temp directory between launches,
    /// matching the original `ChatViewModel.writeTempFile` contract.
    public static func write(_ data: Data, name: String, blobRef: String) throws -> URL {
        let digest = SHA256.hash(data: Data(blobRef.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("matron-attachments", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(sanitisedFilename(name))
        try data.write(to: dest, options: .atomic)
        return dest
    }
}
