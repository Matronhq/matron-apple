import SwiftUI
import MatronModels

/// A project's files in words (a tile's caption, name and extension), pure
/// so each is a plain test and the Mac and iOS pages say it the same way.
public enum ProjectFeedFormat {
    // MARK: Files

    /// A file tile's caption under its name: "#5008 · 1d", "chat · 5d";
    /// no age when the journal sent no `posted_at`.
    public static func fileMeta(_ file: ProjectFile, now: Date) -> String {
        let source: String
        switch file.source {
        case .item(let num): source = "#\(num)"
        case .chat: source = "chat"
        }
        guard let posted = file.postedAt else { return source }
        return "\(source) · \(MissionBoard.ago(posted, now: now))"
    }

    /// A file's name, falling back to its caption, then its kind.
    public static func fileName(_ file: ProjectFile) -> String {
        if let name = file.name, !name.isEmpty { return name }
        if let caption = file.caption, !caption.isEmpty { return ProjectsFormat.oneLine(caption) }
        return file.isImage ? "Image" : "File"
    }

    /// The document tile's label: the name's extension ("PDF"), else the
    /// content type's subtype ("ZIP"), else "FILE". At most 4 characters.
    public static func fileExtension(_ file: ProjectFile) -> String {
        let fromName = (file.name as NSString?)?.pathExtension ?? ""
        let fromType = file.contentType?.split(separator: "/").last.map(String.init) ?? ""
        let raw = !fromName.isEmpty ? fromName : fromType
        guard !raw.isEmpty, raw.count <= 4, raw.allSatisfy({ $0.isLetter || $0.isNumber }) else { return "FILE" }
        return raw.uppercased()
    }
}
