import SwiftUI
import MatronModels
import MatronDesignSystem

/// What the window's title-bar strip shows for the item open on the
/// Decisions page: only its resolve/reopen menu, at the trailing edge. The
/// page has no header over the thread (no chat column publishes one), so the
/// bar is clear there and the thread runs up under it
/// (`itemDetailFillsTitleBar`); the menu is the one control it keeps, where
/// the pinned ⋯ row used to put it.
///
/// Published by `MacItemDetailHost` on the stackless surface only: in a
/// chat's Tasks pane the strip already carries the chat's header, so that
/// pane keeps its in-content ⋯ row.
struct MacItemHeaderProps: Equatable {
    let itemID: String
    /// The view model the menu acts on. A slot rebuilt for the same item
    /// gets a new one, and the header must not keep acting on the old.
    let publisher: ObjectIdentifier
    let isOpen: Bool
    let resolutions: [ItemResolution]
    let isBusy: Bool
    let canReopen: Bool
    let onClose: (ItemResolution) -> Void
    let onReopen: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.itemID == rhs.itemID && lhs.publisher == rhs.publisher
            && lhs.isOpen == rhs.isOpen && lhs.resolutions == rhs.resolutions
            && lhs.isBusy == rhs.isBusy && lhs.canReopen == rhs.canReopen
    }
}

/// Carries the open Decisions item's header to `MacChatHeaderHost`; `nil`
/// everywhere else. One publisher at a time, so the first value wins.
struct MacItemHeaderPreference: PreferenceKey {
    static let defaultValue: MacItemHeaderProps? = nil
    static func reduce(value: inout MacItemHeaderProps?, nextValue: () -> MacItemHeaderProps?) {
        value = value ?? nextValue()
    }
}

/// The item's row in the title-bar strip: the ⋯ menu in a glass circle at
/// the trailing edge, where the chat header keeps its buttons.
struct MacItemHeaderBar: View {
    let props: MacItemHeaderProps

    /// Smaller than the chat header's 38 pt clusters. The glass casts a
    /// soft shadow, and the strip clips the accessory at its bottom edge
    /// (`MacChatHeaderAccessory.height`): a 38 pt capsule left the shadow
    /// 7 pt and it was cut off in a hard line under the button. A 30 pt
    /// circle leaves it 11 pt.
    static let menuDiameter: CGFloat = 30

    var body: some View {
        HStack {
            Spacer()
            if ItemResolveControl.hasActions(isOpen: props.isOpen, resolutions: props.resolutions,
                                             canReopen: props.canReopen) {
                ItemResolveControl(isOpen: props.isOpen, resolutions: props.resolutions, isBusy: props.isBusy,
                                   canReopen: props.canReopen, onClose: props.onClose, onReopen: props.onReopen)
                    .font(.system(size: 15))
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .modifier(MacChatHeaderInactiveDim(opacity: 0.5))
                    .frame(width: Self.menuDiameter, height: Self.menuDiameter)
                    .modifier(MacChatHeaderGlass())
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
    }
}
