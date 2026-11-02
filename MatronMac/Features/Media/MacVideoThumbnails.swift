import AVFoundation
import AppKit
import CryptoKit
import MatronModels
import MatronViewModels
import Observation
import SwiftUI
import WebKit

/// Poster frames for video attachment chips on the Mac.
///
/// A frame needs the file, so a poster costs a fetch. Clips up to
/// `fetchLimit` are fetched in the background, at most two at a time, into
/// the same temp file a click would use, so playing one later costs
/// nothing more. A larger clip gets its poster once it is on disk anyway:
/// after it has been played or downloaded. Posters are kept as small JPEGs
/// in Caches, so a relaunch does not fetch again.
///
/// `@Observable`: a chip that read `poster(…)` redraws when its frame lands.
@MainActor
@Observable
final class MacVideoThumbnails {
    static let shared = MacVideoThumbnails()

    /// Largest clip fetched only to draw its poster.
    static let fetchLimit: Int64 = 50 * 1024 * 1024

    private var posters: [String: NSImage] = [:]
    @ObservationIgnored private var started: Set<String> = []
    @ObservationIgnored private var running = 0
    @ObservationIgnored private var waiting: [() -> Void] = []

    /// The poster for an attachment, or `nil` until there is one; asks for
    /// it on first call. `name` and `blobRef` name the temp file the
    /// attachment is fetched into (`AttachmentTempFiles`); `fetch` gets its
    /// bytes.
    func poster(name: String, blobRef: String, mime: String?, size: Int64?,
                fetch: @escaping @Sendable () async -> Data?) -> Image? {
        let file = AttachmentTempFiles.destination(name: name, blobRef: blobRef)
        let key = file.path
        if let image = posters[key] { return Image(nsImage: image) }
        guard let playback = MediaPlayback.engine(filename: name, mime: mime), playback.isVideo,
              !started.contains(key) else { return nil }
        let onDisk = FileManager.default.fileExists(atPath: key)
        let small = size.map { $0 > 0 && $0 <= Self.fetchLimit } ?? false
        if let cached = Self.readCache(key) {
            started.insert(key)
            Task { @MainActor in posters[key] = cached }
            return nil
        }
        guard onDisk || small else { return nil }
        started.insert(key)
        enqueue { [weak self] done in
            Task { @MainActor in
                defer { done() }
                if !FileManager.default.fileExists(atPath: key) {
                    // No retry on failure: a chip asks on every redraw, and an
                    // expired blob would be fetched again each time. Playing
                    // the clip still draws its poster (`noteLocalFile`).
                    guard let data = await fetch(),
                          (try? AttachmentTempFiles.write(data, name: name, blobRef: blobRef)) != nil else { return }
                }
                await self?.make(from: file, playback: playback)
            }
        }
        return nil
    }

    /// A clip that reached disk some other way (played, or downloaded):
    /// its poster can be drawn now without a fetch.
    func noteLocalFile(_ file: URL, playback: MediaPlayback) {
        let key = file.path
        guard playback.isVideo, posters[key] == nil else { return }
        enqueue { [weak self] done in
            Task { @MainActor in
                defer { done() }
                await self?.make(from: file, playback: playback)
            }
        }
    }

    private func make(from file: URL, playback: MediaPlayback) async {
        let image: NSImage?
        switch playback {
        case .native: image = await Self.nativeFrame(file)
        case .web(let sourceType): image = await WebPosterFrame.capture(file, sourceType: sourceType)
        }
        guard let image else { return }
        posters[file.path] = image
        Self.writeCache(image, key: file.path)
    }

    /// Runs `job` when fewer than two are running; `job` calls its argument
    /// when it has finished.
    private func enqueue(_ job: @escaping (@escaping () -> Void) -> Void) {
        let start = { [weak self] in
            guard let self else { return }
            running += 1
            job { [weak self] in
                guard let self else { return }
                running -= 1
                if !waiting.isEmpty { waiting.removeFirst()() }
            }
        }
        if running < 2 { start() } else { waiting.append(start) }
    }

    /// A frame a second in (or a tenth of the way through a short clip),
    /// as AVFoundation decodes it.
    private static func nativeFrame(_ file: URL) async -> NSImage? {
        let asset = AVURLAsset(url: file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let seconds = duration.isFinite && duration > 0 ? min(1, duration / 10) : 0
        guard let (cgImage, _) = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: Disk cache

    private static let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("matron-video-posters", isDirectory: true)

    private static func cacheURL(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(digest + ".jpg")
    }

    private static func readCache(_ key: String) -> NSImage? {
        NSImage(contentsOf: cacheURL(key))
    }

    private static func writeCache(_ image: NSImage, key: String) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? jpeg.write(to: cacheURL(key), options: .atomic)
    }
}

/// A WebM or Matroska poster frame: AVFoundation can't decode these, so a
/// hidden WebKit page seeks its `<video>` a second in and snapshots it.
/// WebKit only loads media for a page in a window, so the view sits in a
/// transparent, click-through window far off screen for the capture.
@MainActor
enum WebPosterFrame {
    static func capture(_ file: URL, sourceType: String) async -> NSImage? {
        let size = CGSize(width: 640, height: 360)
        let relay = Relay()
        let config = WKWebViewConfiguration()
        config.userContentController.add(relay, name: "matron")
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            config.userContentController.removeScriptMessageHandler(forName: "matron")
            window.orderOut(nil)
            window.contentView = nil
        }
        let page = file.deletingLastPathComponent().appendingPathComponent(".matron-poster.html")
        guard (try? Self.page(fileName: file.lastPathComponent, sourceType: sourceType)
            .write(to: page, atomically: true, encoding: .utf8)) != nil else { return nil }
        let answer: String? = await withCheckedContinuation { continuation in
            relay.answer = { continuation.resume(returning: $0) }
            webView.loadFileURL(page, allowingReadAccessTo: file.deletingLastPathComponent())
            // A file WebKit can't open may never post: give up after 10 s.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                relay.finish(nil)
            }
        }
        guard let answer, answer.hasPrefix("ready ") else { return nil }
        // "ready <width>x<height>": snapshot only the letterboxed frame.
        let dims = answer.dropFirst(6).split(separator: "x").compactMap { Double($0) }
        let snapshot = WKSnapshotConfiguration()
        if dims.count == 2, dims[0] > 0, dims[1] > 0 {
            let scale = min(size.width / dims[0], size.height / dims[1])
            let fitted = CGSize(width: dims[0] * scale, height: dims[1] * scale)
            snapshot.rect = CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                                   width: fitted.width, height: fitted.height)
        }
        return try? await webView.takeSnapshot(configuration: snapshot)
    }

    nonisolated static func page(fileName: String, sourceType: String) -> String {
        let src = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src file:; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
        <style>html,body{margin:0;width:100%;height:100%;background:#000;overflow:hidden}
        video{width:100%;height:100%;object-fit:contain;display:block}</style></head>
        <body><video muted preload="auto"><source src="\(src)" type="\(sourceType)"></video>
        <script>
        const v = document.querySelector('video');
        const post = (m) => webkit.messageHandlers.matron.postMessage(m);
        v.addEventListener('loadeddata', () => { v.currentTime = Math.min(1, (v.duration || 2) / 10); });
        v.addEventListener('seeked', () => setTimeout(() => post('ready ' + v.videoWidth + 'x' + v.videoHeight), 100));
        v.addEventListener('error', () => post('error'));
        v.querySelector('source').addEventListener('error', () => post('error'));
        </script></body></html>
        """
    }

    private final class Relay: NSObject, WKScriptMessageHandler {
        var answer: ((String?) -> Void)?

        func finish(_ value: String?) {
            answer?(value)
            answer = nil
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { finish(message.body as? String) }
        }
    }
}
