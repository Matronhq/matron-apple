import SwiftUI
import MatronChat

/// Mac analogue of `EventSourceSheet` (iOS Task 16). Renders the row's
/// DTO as pretty-printed JSON in a scrollable, selectable `Text`.
///
/// Mac differences vs iOS:
///   - No `NavigationStack` / nav bar — Mac sheets render bare.
///   - Sized via `.frame(minWidth:minHeight:)` so the JSON dump has room.
///   - "Done" button at the bottom-trailing edge with `.defaultAction`
///     keyboard shortcut (⏎); a hidden `.cancelAction` button picks up Esc.
///
/// Phase 2 only has access to the DTO — `item.prettyJSON()` synthesises a
/// JSON-shaped record. Phase 3+ will swap this for the SDK's raw event
/// JSON via `EventTimelineItem.originalJson`.
struct MacEventSourceSheet: View {
    let item: TimelineItem
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Event source")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                Text(item.prettyJSON())
                    .font(.system(.callout, design: .monospaced))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
                // Hidden button so Esc also dismisses, mirroring
                // `MacBotProfileSheet`'s pattern.
                Button("") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
            .padding(12)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 480)
    }
}
