import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// How the Mac app plays an audio or video attachment in place, judged from
/// its filename (and MIME type when the name has no extension) before any
/// bytes are fetched, so a click can open the player at once.
public enum MediaPlayback: Equatable, Sendable {
    /// AVFoundation's own player: everything `AVURLAsset.audiovisualTypes()`
    /// lists (QuickTime, MPEG-4, MP3, WAV, AVI, Ogg audio …).
    case native(isVideo: Bool)
    /// A WebKit `<video>` element, for WebM and Matroska, which
    /// AVFoundation cannot open (browser screen recordings are WebM).
    /// `sourceType` is the type the page declares: WebKit only reads
    /// Matroska when told it is WebM, its subset.
    case web(sourceType: String)

    public var isVideo: Bool {
        switch self {
        case .native(let isVideo): return isVideo
        case .web(let sourceType): return sourceType.hasPrefix("video/")
        }
    }

    /// The way to play `filename` in the app, or `nil` when it is not
    /// audio or video the app can play, and goes to the default app.
    public static func engine(filename: String, mime: String? = nil) -> MediaPlayback? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = mime?.lowercased().split(separator: ";").first.map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        if let web = webSourceType(ext: ext, mime: ext.isEmpty ? mime : nil) {
            return .web(sourceType: web)
        }
        let type = ext.isEmpty
            ? mime.flatMap { UTType(mimeType: $0) }
            : UTType(filenameExtension: ext)
        guard let type, type.conforms(to: .audiovisualContent),
              nativeTypes.contains(where: { type.conforms(to: $0) }) else { return nil }
        return .native(isVideo: type.conforms(to: .movie))
    }

    private static func webSourceType(ext: String, mime: String?) -> String? {
        switch ext {
        case "webm", "mkv": return "video/webm"
        case "weba", "mka": return "audio/webm"
        default: break
        }
        switch mime {
        case "video/webm", "video/x-matroska", "video/matroska": return "video/webm"
        case "audio/webm", "audio/x-matroska", "audio/matroska": return "audio/webm"
        default: return nil
        }
    }

    private static let nativeTypes: [UTType] =
        AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }
}
