import AVFoundation
import AVKit
import AppKit
import MatronModels
import MatronViewModels
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Routing for an attachment click on Mac. Audio and video the app can
/// play (`MediaPlayback`) open the in-app player at once, which fetches
/// the file behind its own spinner — the Mac counterpart of iOS
/// `FilePreviewSheet`'s QuickLook player; everything else is fetched and
/// goes to the user's default app as before. Handing an `.m4a` to
/// `NSWorkspace` is what used to launch Music for every voice note.
enum MacAttachmentOpener {
    /// Whether `url` names a file the in-app player can play.
    static func playsInApp(_ url: URL) -> Bool {
        MediaPlayback.engine(filename: url.lastPathComponent) != nil
    }

    /// A filename for an attachment that arrived without one: "attachment"
    /// plus the extension `mime` implies ("attachment.m4a" for
    /// `audio/mp4`), so the temp file keeps a type.
    static func fallbackFilename(mime: String) -> String {
        let base = "attachment"
        // `audio/mp4` is how voice notes are sent; UTType maps it to .mp4,
        // which AVFoundation would treat as a movie.
        if mime == "audio/mp4" { return base + ".m4a" }
        if mime == "video/x-matroska" { return base + ".mkv" }
        guard let ext = UTType(mimeType: mime)?.preferredFilenameExtension else { return base }
        return base + "." + ext
    }

    /// A chat attachment as a temp file for `open`'s `load`. A fetch of the
    /// same file already running (a Download, or an earlier click) makes
    /// `writeTempFile` answer `nil` at once, which the player would show as
    /// a failed fetch, so this waits for that one and takes its file.
    @MainActor
    static func tempFile(_ mxc: URL, filename: String, in viewModel: ChatViewModel) async -> URL? {
        // Fetched already for its poster (`MacVideoThumbnails`), or being
        // fetched for it now.
        if let onDisk = AttachmentTempFiles.existingFile(name: filename, blobRef: mxc.absoluteString) {
            return onDisk
        }
        if let posterFetch = await MacVideoThumbnails.shared.inFlightFile(name: filename, blobRef: mxc.absoluteString) {
            return posterFetch
        }
        while viewModel.isDownloadingFile(mxc) {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return nil }
        }
        return await viewModel.writeTempFile(mxcURL: mxc, filename: filename)
    }

    /// Opens an attachment: playable media in the player sheet straight
    /// away (`load` runs inside it), anything else in the default app once
    /// `load` has fetched it. A file that is not an everyday document (an
    /// app, a script, a link file …) is confirmed first: it came from
    /// whoever sent it, and its default app may run it.
    @MainActor
    static func open(filename: String, mime: String?, load: @escaping @MainActor () async -> URL?,
                     preview: (MediaPlayerPreview) -> Void) {
        if let playback = MediaPlayback.engine(filename: filename, mime: mime) {
            preview(MediaPlayerPreview(filename: filename, mime: mime, playback: playback, load: load))
        } else {
            Task { @MainActor in
                guard let url = await load() else { return }
                switch AttachmentOpenPolicy.opensWithoutAsking(filename: url.lastPathComponent)
                    ? .open : confirmOpen(url) {
                case .open: NSWorkspace.shared.open(url)
                case .showInFinder: NSWorkspace.shared.activateFileViewerSelecting([url])
                case .cancel: break
                }
            }
        }
    }

    enum OpenChoice { case open, showInFinder, cancel }

    /// Asks before handing a file that is not an everyday document to its
    /// default app. Cancel is the default button.
    @MainActor
    private static func confirmOpen(_ url: URL) -> OpenChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open \u{201C}\(url.lastPathComponent)\u{201D}?"
        let app = NSWorkspace.shared.urlForApplication(toOpen: url)
            .map { FileManager.default.displayName(atPath: $0.path) }
        alert.informativeText = (app.map { "It will open in \($0). " } ?? "")
            + "This kind of file can run commands or open other apps. Open it only if you expected it."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Show in Finder")
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .open
        case .alertThirdButtonReturn: return .showInFinder
        default: return .cancel
        }
    }
}

/// What a `.sheet(item:)` keys on for the in-app player. Per-present UUID
/// so clicking the same clip twice re-mounts the sheet.
struct MediaPlayerPreview: Identifiable {
    let id = UUID()
    let filename: String
    let mime: String?
    let playback: MediaPlayback
    /// The attachment as a local file: fetched into the temp cache, or the
    /// copy already there. `nil` when it couldn't be fetched.
    let load: @MainActor () async -> URL?

    var isVideo: Bool { playback.isVideo }
}

extension View {
    /// Presents `MacMediaPlayerSheet` for `item`.
    func mediaPlayerSheet(item: Binding<MediaPlayerPreview?>) -> some View {
        sheet(item: item) { preview in
            MacMediaPlayerSheet(preview: preview, onDone: { item.wrappedValue = nil })
        }
    }
}

/// In-app player for an audio or video attachment. It opens on the click,
/// shows a spinner while the file comes down, then plays: AVKit's own
/// controls (scrub, volume, speed, AirPlay, full screen for video) for what
/// AVFoundation reads, a WebKit `<video>` for WebM and Matroska. Download,
/// the default app and Finder stay one click away.
struct MacMediaPlayerSheet: View {
    let preview: MediaPlayerPreview
    let onDone: () -> Void

    private enum Phase {
        case loading
        case native(URL, AVPlayer)
        case web(URL, WebMediaPlayer)
        /// The file came down but won't play: a supported extension does
        /// not promise a supported codec, so the sheet says so instead of
        /// showing a player that never starts. Open / Download stay.
        case failed(URL)
        /// The fetch itself failed (network, or the file has expired).
        case unavailable
    }

    @State private var phase = Phase.loading
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .task { await load() }
        .onDisappear { stop() }
    }

    private var fileURL: URL? {
        switch phase {
        case .native(let url, _), .web(let url, _), .failed(let url): return url
        case .loading, .unavailable: return nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            notice(systemImage: nil, message: "Loading…")
        case .unavailable:
            notice(systemImage: "exclamationmark.triangle",
                   message: "Matron couldn’t fetch this file. It may have expired, or the connection dropped.")
        case .failed:
            notice(systemImage: "exclamationmark.triangle",
                   message: "Matron can’t play this file. Download it or open it in another app instead.")
        case .native(_, let player):
            if preview.isVideo {
                PlayerView(player: player, controlsStyle: .floating)
                    .frame(minWidth: 640, idealWidth: 720, minHeight: 360, idealHeight: 405)
            } else {
                audioHeader
                PlayerView(player: player, controlsStyle: .inline)
                    .frame(width: 420, height: 50)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        case .web(_, let player):
            if preview.isVideo {
                WebPlayerView(player: player)
                    .frame(minWidth: 640, idealWidth: 720, minHeight: 360, idealHeight: 405)
            } else {
                audioHeader
                WebPlayerView(player: player)
                    .frame(width: 420, height: 54)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
    }

    /// Fetches the file, then starts the player for it and watches for a
    /// failure to decode.
    private func load() async {
        guard let url = await preview.load() else {
            phase = .unavailable
            return
        }
        guard !Task.isCancelled else { return }
        MacVideoThumbnails.shared.noteLocalFile(url, playback: preview.playback)
        switch preview.playback {
        case .native:
            let player = AVPlayer(url: url)
            phase = .native(url, player)
            player.play()
            guard let item = player.currentItem else { return }
            for await status in item.publisher(for: \.status).values where status == .failed {
                player.pause()
                phase = .failed(url)
                return
            }
        case .web(let sourceType):
            let player = WebMediaPlayer(file: url, sourceType: sourceType, isVideo: preview.isVideo,
                                        onFailure: { phase = .failed(url) })
            phase = .web(url, player)
        }
    }

    private func stop() {
        switch phase {
        case .native(_, let player): player.pause()
        case .web(_, let player): player.stop()
        default: break
        }
    }

    /// Stops playback before the sheet animates away, so Done / Esc is
    /// silent at once rather than when `onDisappear` fires.
    private func close() {
        stop()
        onDone()
    }

    private func notice(systemImage: String?, message: String) -> some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text(preview.filename)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(minWidth: preview.isVideo ? 640 : 420, minHeight: preview.isVideo ? 360 : nil)
        .padding(24)
    }

    private var audioHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text(preview.filename)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
        .padding(.bottom, 12)
        .padding(.horizontal, 20)
    }

    private var footer: some View {
        HStack {
            Button("Download…") {
                guard let url = fileURL else { return }
                Task { @MainActor in
                    saveError = await MacAttachmentSaver.save(
                        url, filename: preview.filename,
                        contentType: MacAttachmentSaver.contentType(mime: preview.mime, filename: preview.filename))
                }
            }
            .disabled(fileURL == nil)
            Button(openTitle) {
                guard let url = fileURL else { return }
                NSWorkspace.shared.open(url)
                close()
            }
            .disabled(fileURL == nil)
            Button("Show in Finder") {
                guard let url = fileURL else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(fileURL == nil)
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            Button("Done", action: close)
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    /// "Open in Music" / "Open in QuickTime Player" — names the app the
    /// file would have gone to, falling back to a plain label.
    private var openTitle: String {
        guard let url = fileURL, let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            return "Open Externally"
        }
        var name = FileManager.default.displayName(atPath: app.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        return "Open in \(name)"
    }
}

/// `AVPlayerView` for SwiftUI. `VideoPlayer` has no inline (audio-bar)
/// controls style on macOS, so the AppKit view is wrapped directly.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let controlsStyle: AVPlayerViewControlsStyle

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = controlsStyle
        view.showsFullScreenToggleButton = controlsStyle == .floating
        view.allowsPictureInPicturePlayback = controlsStyle == .floating
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// A WebKit page holding one `<video>` (or `<audio>`) element with the
/// browser's own controls, for the formats AVFoundation can't read. The
/// page is a file written beside the attachment, so WebKit gets read
/// access to that one directory and nothing else; it makes no network
/// requests. A load error comes back through `onFailure`.
@MainActor
final class WebMediaPlayer {
    let webView: WKWebView
    /// Released by `stop()`: its failure callback writes the sheet's state,
    /// which holds this player, so keeping it would leak the pair.
    private var messages: MessageRelay?

    /// The page, written beside `file` so it can name it relatively.
    nonisolated static func pageURL(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(".matron-player.html")
    }

    /// The page's markup: autoplaying, with controls, reporting an error
    /// on the element or its source to the `matron` message handler.
    nonisolated static func page(fileName: String, sourceType: String, isVideo: Bool) -> String {
        let tag = isVideo ? "video" : "audio"
        let src = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src file:; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
        <style>html,body{margin:0;height:100%;background:\(isVideo ? "#000" : "transparent");overflow:hidden}
        \(tag){width:100%;height:100%;display:block}</style></head>
        <body><\(tag) controls autoplay\(isVideo ? " playsinline" : "")><source src="\(src)" type="\(sourceType)"></\(tag)>
        <script>
        const m = document.querySelector('\(tag)');
        const fail = () => webkit.messageHandlers.matron.postMessage('error');
        m.addEventListener('error', fail);
        m.querySelector('source').addEventListener('error', fail);
        </script></body></html>
        """
    }

    init(file: URL, sourceType: String, isVideo: Bool, onFailure: @escaping @MainActor () -> Void) {
        let relay = MessageRelay(onFailure: onFailure)
        messages = relay
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(relay, name: "matron")
        webView = WKWebView(frame: .zero, configuration: config)
        let page = Self.pageURL(for: file)
        do {
            try Self.page(fileName: file.lastPathComponent, sourceType: sourceType, isVideo: isVideo)
                .write(to: page, atomically: true, encoding: .utf8)
            webView.loadFileURL(page, allowingReadAccessTo: file.deletingLastPathComponent())
        } catch {
            Task { @MainActor in onFailure() }
        }
    }

    func stop() {
        webView.pauseAllMediaPlayback()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "matron")
        messages = nil
    }

    /// The script handler, kept apart from the player: the content
    /// controller retains it, so it must not retain the web view back.
    private final class MessageRelay: NSObject, WKScriptMessageHandler {
        let onFailure: @MainActor () -> Void
        init(onFailure: @escaping @MainActor () -> Void) { self.onFailure = onFailure }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { onFailure() }
        }
    }
}

private struct WebPlayerView: NSViewRepresentable {
    let player: WebMediaPlayer

    func makeNSView(context: Context) -> WKWebView { player.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
