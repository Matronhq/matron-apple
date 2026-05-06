import SwiftUI

/// Fullscreen image viewer presented from a chat attachment tap. iOS
/// supports pinch-zoom + swipe-down-to-dismiss; Mac displays the
/// resolved `Image` with a "Done" button (Mac doesn't have the touch
/// gestures, and adding click-and-drag pan would diverge from the
/// platform's native QuickLook conventions).
///
/// The `Image` is taken pre-resolved (via `ChatViewModel.image(for:)`)
/// so the viewer stays a leaf View — avoids dragging `MediaService`
/// into `MatronDesignSystem` for one sheet.
public struct AttachmentFullscreenViewer: View {
    private let image: Image
    private let onDismiss: () -> Void

    public init(image: Image, onDismiss: @escaping () -> Void) {
        self.image = image
        self.onDismiss = onDismiss
    }

    public var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    // MARK: - iOS

    #if !os(macOS)
    /// iOS body. Pinch-to-zoom via `MagnificationGesture` clamped to a
    /// sane min/max so the user can't accidentally collapse or
    /// fly-zoom past the viewable range. Swipe-down dismiss via
    /// `DragGesture`: only translation > 100pt downward triggers
    /// dismissal so accidental scroll inertia doesn't close the
    /// sheet.
    @ViewBuilder
    private var iosBody: some View {
        FullscreenImageBody(image: image, onDismiss: onDismiss)
    }
    #endif

    // MARK: - Mac

    #if os(macOS)
    @ViewBuilder
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .padding()
            }
            image
                .resizable()
                .scaledToFit()
                .padding()
            Spacer(minLength: 0)
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Color.black.opacity(0.85))
        .accessibilityLabel("Image preview")
    }
    #endif
}

#if !os(macOS)
/// iOS subview that hosts the gesture state. Lifting it out of
/// `AttachmentFullscreenViewer` keeps the parent stateless so the
/// `#if` switch above stays a one-line `body` without leaking
/// gesture-state ownership across platforms.
private struct FullscreenImageBody: View {
    let image: Image
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var dragOffset: CGSize = .zero

    private static let minScale: CGFloat = 1.0
    private static let maxScale: CGFloat = 4.0
    /// Threshold for the swipe-down dismiss. 100pt is the same value
    /// SwiftUI's interactive sheet dismiss uses internally and reads
    /// as "intentional swipe" without tripping on a normal scroll
    /// inertia bounce.
    private static let dismissThreshold: CGFloat = 100

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            image
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(dragOffset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(
                                max(Self.minScale, value.magnitude),
                                Self.maxScale
                            )
                        }
                        .onEnded { _ in
                            // Snap back to 1.0 if the user pinch-out
                            // released below the floor; the floor's
                            // already enforced in `onChanged`, but a
                            // double-tap-style "reset zoom" feels
                            // natural when the user releases at the
                            // exact min-scale boundary.
                            if scale < Self.minScale + 0.05 {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    scale = Self.minScale
                                }
                            }
                        }
                )
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            // Only track downward drags — upward /
                            // horizontal dragging shouldn't shift
                            // the image (we don't pan when zoomed
                            // either; that's a v2 feature).
                            if value.translation.height > 0 {
                                dragOffset = CGSize(
                                    width: 0,
                                    height: value.translation.height
                                )
                            }
                        }
                        .onEnded { value in
                            if value.translation.height > Self.dismissThreshold {
                                onDismiss()
                            } else {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    dragOffset = .zero
                                }
                            }
                        }
                )

            // Top-trailing close button — provides a no-gesture path
            // out for VoiceOver users / anyone unfamiliar with the
            // swipe-down convention.
            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white, .black.opacity(0.4))
                            .padding()
                    }
                    .accessibilityLabel("Close image preview")
                }
                Spacer()
            }
        }
    }
}
#endif
