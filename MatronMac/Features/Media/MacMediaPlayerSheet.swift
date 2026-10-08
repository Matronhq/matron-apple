import AVFoundation
import AVKit
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Routing for a downloaded attachment file on Mac. Audio and video that
/// AVFoundation can play stay in the app (`MacMediaPlayerSheet`, the Mac
/// counterpart of iOS `FilePreviewSheet`'s QuickLook player); everything
/// else goes to the user's default app as before. Handing an `.m4a` to
/// `NSWorkspace` is what used to launch Music for every voice note.
enum MacAttachmentOpener {
    /// Whether `url` names a file the in-app player can play, judged by its
    /// extension against `AVURLAsset.audiovisualTypes()` — the same list
    /// AVFoundation itself accepts, so a `.webm` or `.mkv` (which it cannot
    /// play) still goes to an external app.
    static func playsInApp(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .audiovisualContent) else { return false }
        return playableTypes.contains { type.conforms(to: $0) }
    }

    private static let playableTypes: [UTType] =
        AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }

    /// A filename for an attachment that arrived without one: "attachment"
    /// plus the extension `mime` implies ("attachment.m4a" for
    /// `audio/mp4`), so the temp file keeps a type.
    static func fallbackFilename(mime: String) -> String {
        let base = "attachment"
        // `audio/mp4` is how voice notes are sent; UTType maps it to .mp4,
        // which AVFoundation would treat as a movie.
        if mime == "audio/mp4" { return base + ".m4a" }
        guard let ext = UTType(mimeType: mime)?.preferredFilenameExtension else { return base }
        return base + "." + ext
    }

    /// Opens a downloaded attachment: `preview` for playable media, the
    /// default app otherwise.
    @MainActor
    static func open(_ url: URL, filename: String, preview: (MediaPlayerPreview) -> Void) {
        if playsInApp(url) {
            preview(MediaPlayerPreview(url: url, filename: filename))
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// What a `.sheet(item:)` keys on for the in-app player. Per-present UUID
/// so tapping the same clip twice re-mounts the sheet.
struct MediaPlayerPreview: Identifiable {
    let id = UUID()
    let url: URL
    let filename: String

    var isVideo: Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }
}

extension View {
    /// Presents `MacMediaPlayerSheet` for `item`.
    func mediaPlayerSheet(item: Binding<MediaPlayerPreview?>) -> some View {
        sheet(item: item) { preview in
            MacMediaPlayerSheet(preview: preview, onDone: { item.wrappedValue = nil })
        }
    }
}

/// In-app player for an audio or video attachment: AVKit's own controls
/// (scrub, volume, speed, AirPlay, full screen for video), starting on
/// open, with the way out to the default app and to Finder kept one
/// click away.
struct MacMediaPlayerSheet: View {
    let preview: MediaPlayerPreview
    let onDone: () -> Void

    @State private var player: AVPlayer
    /// The item failed to load or decode: a supported extension does not
    /// promise a supported codec, so the sheet says so instead of showing
    /// a player that never starts. The "Open in …" button stays.
    @State private var failed = false

    init(preview: MediaPlayerPreview, onDone: @escaping () -> Void) {
        self.preview = preview
        self.onDone = onDone
        _player = State(initialValue: AVPlayer(url: preview.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            if failed {
                failureNotice
            } else if preview.isVideo {
                PlayerView(player: player, controlsStyle: .floating)
                    .frame(minWidth: 480, idealWidth: 720, minHeight: 270, idealHeight: 405)
            } else {
                audioHeader
                PlayerView(player: player, controlsStyle: .inline)
                    .frame(width: 420, height: 50)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            Divider()
            footer
        }
        .onAppear { player.play() }
        .onDisappear { player.pause() }
        .onReceive(statusPublisher) { status in
            if status == .failed {
                player.pause()
                failed = true
            }
        }
    }

    private var statusPublisher: AnyPublisher<AVPlayerItem.Status, Never> {
        guard let item = player.currentItem else { return Empty().eraseToAnyPublisher() }
        // AVFoundation posts status KVO on its own queue; `failed` is view
        // state, so hop to the main queue before `onReceive` writes it.
        return item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// Stops playback before the sheet animates away, so Done / Esc is
    /// silent at once rather than when `onDisappear` fires.
    private func close() {
        player.pause()
        onDone()
    }

    private var failureNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(preview.filename)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text("Matron can’t play this file. Open it in another app instead.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 420)
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
            Button {
                NSWorkspace.shared.open(preview.url)
                close()
            } label: {
                Text(openTitle)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([preview.url])
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
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: preview.url) else {
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
