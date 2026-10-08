import QuickLook
import SwiftUI

/// Preview sheet for a downloaded file attachment. QuickLook-previewable
/// types (video, audio, PDF, office docs, …) open in an embedded
/// `QLPreviewController` — video/audio get the system player with scrub
/// and AirPlay, and QuickLook's own toolbar keeps Share reachable.
/// Everything else falls back to the filename + `ShareLink` layout that
/// used to be the only path.
struct FilePreviewSheet: View {
    let url: URL
    let filename: String
    let onDone: () -> Void

    var body: some View {
        if QuickLookPreview.canPreview(url) {
            QuickLookPreview(url: url, onDone: onDone)
                .ignoresSafeArea()
                .presentationDetents([.large])
        } else {
            shareFallback
        }
    }

    private var shareFallback: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.top, 32)
            Text(filename)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)
            Button("Done", action: onDone)
                .padding(.top, 4)
            Spacer()
        }
        .padding()
        .presentationDetents([.medium])
    }
}

/// `QLPreviewController` wrapped for SwiftUI presentation inside a sheet.
/// Wrapped in a `UINavigationController` because QuickLook renders its
/// title and Share button into the hosting navigation bar; without one
/// the preview shows bare content with no chrome. QuickLook only adds
/// its own Done button when it is the modally-presented root controller,
/// which it isn't here — so we install one that closes the SwiftUI sheet
/// (swipe-down also works).
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void

    static func canPreview(_ url: URL) -> Bool {
        QLPreviewController.canPreview(url as NSURL)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { _ in onDone() })
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {
        // The sheet is item-driven, so a new attachment means a fresh
        // representable — but keep the coordinator honest anyway.
        if context.coordinator.url != url {
            context.coordinator.url = url
            (navigation.viewControllers.first as? QLPreviewController)?.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
