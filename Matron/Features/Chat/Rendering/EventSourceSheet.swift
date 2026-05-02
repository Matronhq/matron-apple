import SwiftUI
import MatronChat

/// Long-press / "View source" sheet for a timeline row (Phase 2 Task 16).
///
/// Renders the row's DTO as pretty-printed JSON in a scrollable, selectable
/// `Text`. Phase 2 only has access to the DTO — Phase 3+ will swap
/// `item.prettyJSON()` for the SDK's raw event JSON via
/// `EventTimelineItem.originalJson`.
///
/// Wrapped in a `NavigationStack` with a Done button in the
/// `.confirmationAction` slot so the sheet has a clear dismissal affordance
/// on iOS (where there's no Esc key).
struct EventSourceSheet: View {
    let item: TimelineItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(item.prettyJSON())
                    .font(.system(.callout, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .navigationTitle("Event source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
