import SwiftUI
import MatronEvents

/// The `coordinator` marker's inline row (Coordinator redesign §3e): one
/// quiet line, styled like `MissionNotice` but not a button — there is
/// nowhere to navigate to.
public struct CoordinatorNotice: View {
    let marker: CoordinatorMarkerEvent

    public init(marker: CoordinatorMarkerEvent) { self.marker = marker }

    public var body: some View {
        Label(marker.text, systemImage: "person.crop.circle.badge.checkmark")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
    }
}
