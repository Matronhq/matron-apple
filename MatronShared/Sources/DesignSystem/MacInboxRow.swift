import SwiftUI

#if os(macOS)
/// Mac-only row chrome shared by the Missions and Decisions lists: a
/// full-width hairline separator that runs edge to edge of the column,
/// like Mail, on a `.plain` `List`.
///
/// A zero `listRowInsets` is required for the separator alignment guides'
/// math below to hold, so the horizontal breathing room that would
/// normally live in the row insets moves onto the row content itself
/// instead (`.padding(.horizontal, 12)`) — apply this modifier to the
/// row's `Button`/label wrapper at the call site, never inside the shared
/// row content view itself (`MissionRowView`, `ItemRow`), since `ItemRow`
/// is also used unmodified by `ItemsListView`.
///
/// Even with `listRowInsets(EdgeInsets())`, macOS's `.plain` `List` still
/// applies its own ~8pt content inset, so `0`/`width` alignment guides
/// land ~8pt short of the real column edge on both sides. Overshooting
/// the guides by that same 8pt cancels the List's inset and lands the
/// hairline flush with the edge (verified in a standalone AppKit-hosted
/// `List` harness).
struct MacInboxRow: ViewModifier {
    let hideTopSeparator: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .listRowInsets(EdgeInsets())
            .alignmentGuide(.listRowSeparatorLeading) { _ in -8 }
            .alignmentGuide(.listRowSeparatorTrailing) { d in d.width + 8 }
            .listRowSeparator(.visible, edges: .bottom)
            .listRowSeparator(hideTopSeparator ? .hidden : .visible, edges: .top)
    }
}

extension View {
    /// Full-width separator + horizontal padding for an inbox-style Mac
    /// list row (Missions, Decisions). `hideTopSeparator` drops the
    /// hairline above a section's (or the list's) first row so it
    /// doesn't double the header's own bottom line.
    func macInboxRow(hideTopSeparator: Bool) -> some View {
        modifier(MacInboxRow(hideTopSeparator: hideTopSeparator))
    }
}
#endif
