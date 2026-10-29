#if os(macOS)
import SwiftUI

/// Sizes a window's root view without consulting its content.
///
/// With `.windowResizability(.contentMinSize)` the window asks its root
/// view for a minimum size on window layouts. A root frame that only sets
/// minimums leaves the rest of each answer to the content, so every such
/// probe measured the whole split-view tree: sidebar, transcript, composer.
/// Busy samples on a Mac showed those passes taking up to 3 s.
///
/// Setting min, ideal and max on both axes in one frame lets SwiftUI answer
/// the zero, unspecified and infinite proposals from the frame alone, as
/// the chat panes' `SplitPaneFrame` does. The content still lays out at the
/// size the window gives it.
public struct WindowRootFrame: ViewModifier {
    public let minSize: CGSize
    public let idealSize: CGSize

    public init(minSize: CGSize, idealSize: CGSize) {
        self.minSize = minSize
        self.idealSize = idealSize
    }

    public func body(content: Content) -> some View {
        content.frame(minWidth: minSize.width, idealWidth: idealSize.width, maxWidth: .infinity,
                      minHeight: minSize.height, idealHeight: idealSize.height, maxHeight: .infinity)
    }
}

public extension View {
    func windowRootFrame(minSize: CGSize, idealSize: CGSize) -> some View {
        modifier(WindowRootFrame(minSize: minSize, idealSize: idealSize))
    }
}
#endif
