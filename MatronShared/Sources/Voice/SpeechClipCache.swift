import CryptoKit
import Foundation

/// A small on-disk cache of cloud clips for the fixed phrases ("Sent",
/// "Three things need you"), so they play at once and cost nothing after
/// first use (spec 2026-10-03 §3, "Playing"). Keyed by the phone's own
/// hash of voice and text: the journal's `ETag` is not revalidated.
/// Replies are never cached here; the journal keeps those for a day.
public struct SpeechClipCache: Sendable {
    public let directory: URL
    /// Oldest clips beyond this many are deleted on write. The default
    /// holds every fixed phrase in both cloud voices and under
    /// `defaultVoiceKey` (a test pins that it still does).
    public let limit: Int

    /// The `voice` a clip is kept under when the user has chosen none and
    /// the journal has not yet said which voice is its default.
    public static let defaultVoiceKey = "default"

    public init(directory: URL, limit: Int = 96) {
        self.directory = directory
        self.limit = limit
    }

    /// `Library/Caches/voice-clips`: the system may empty it; nothing is lost.
    public static func standard() -> SpeechClipCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return SpeechClipCache(directory: caches.appendingPathComponent("voice-clips", isDirectory: true))
    }

    /// Only the fixed phrases (`VoicePhrases.fixed`) are worth keeping.
    public static func isCacheable(_ text: String) -> Bool {
        fixed.contains(text)
    }

    private static let fixed = Set(VoicePhrases.fixed)

    static func key(text: String, voice: String) -> String {
        let digest = SHA256.hash(data: Data("\(voice)\n\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func url(text: String, voice: String) -> URL {
        directory.appendingPathComponent(Self.key(text: text, voice: voice) + ".mp3")
    }

    public func clip(text: String, voice: String) -> Data? {
        guard let data = try? Data(contentsOf: url(text: text, voice: voice)), !data.isEmpty else { return nil }
        return data
    }

    public func store(_ audio: Data, text: String, voice: String) {
        guard Self.isCacheable(text), !audio.isEmpty else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? audio.write(to: url(text: text, voice: voice), options: .atomic)
        trim()
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func trim() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > limit else { return }
        let dated = files.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - limit) {
            try? manager.removeItem(at: url)
        }
    }
}
