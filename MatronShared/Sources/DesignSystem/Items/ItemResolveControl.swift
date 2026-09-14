import SwiftUI
import MatronModels

/// The item's resolve/reopen menu — an `ellipsis.circle` in the top
/// right corner (the iOS navigation bar, the Mac thread header), not a
/// button above the keyboard. It used to sit in an action bar over the
/// composer, where a "Close" read as "close this screen" and, worse,
/// offered "answered" on a question nobody had replied to. Closing is
/// the exception, not the next step after typing: a question is
/// answered by *replying*, and a task or decision is usually settled in
/// the thread too, so the control lives out of the composer's way and
/// names each outcome as the act it performs ("Mark done", "Dismiss").
/// The host decides which resolutions are honest to offer
/// (`ItemDetailViewModel.availableResolutions`).
public struct ItemResolveControl: View {
    let isOpen: Bool
    let resolutions: [ItemResolution]
    let isBusy: Bool
    let onClose: (ItemResolution) -> Void
    let onReopen: () -> Void

    public init(isOpen: Bool, resolutions: [ItemResolution], isBusy: Bool,
                onClose: @escaping (ItemResolution) -> Void, onReopen: @escaping () -> Void) {
        self.isOpen = isOpen; self.resolutions = resolutions; self.isBusy = isBusy
        self.onClose = onClose; self.onReopen = onReopen
    }

    /// The menu entry for a resolution — what marking the item that way
    /// *does*, not the resulting state.
    public static func actionLabel(_ resolution: ItemResolution) -> String {
        switch resolution {
        case .done: return "Mark done"
        case .answered: return "Mark answered"
        case .decided: return "Mark decided"
        case .reversed: return "Reverse"
        case .cancelled: return "Dismiss"
        }
    }

    static func symbol(_ resolution: ItemResolution) -> String {
        switch resolution {
        case .done, .answered, .decided: return "checkmark.circle"
        case .reversed: return "arrow.uturn.backward.circle"
        case .cancelled: return "xmark.circle"
        }
    }

    public var body: some View {
        if isOpen ? !resolutions.isEmpty : true {
            Menu {
                if isOpen {
                    ForEach(resolutions, id: \.self) { r in
                        Button(role: r == .cancelled ? .destructive : nil) { onClose(r) } label: {
                            Label(Self.actionLabel(r), systemImage: Self.symbol(r))
                        }
                    }
                } else {
                    Button { onReopen() } label: { Label("Reopen", systemImage: "arrow.uturn.backward.circle") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(isBusy)
            .accessibilityLabel("Item actions")
        }
    }
}
