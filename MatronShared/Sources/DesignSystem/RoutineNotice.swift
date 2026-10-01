import SwiftUI
import MatronEvents

/// The `routine` marker's inline row: one quiet line, styled like
/// `CoordinatorNotice`. An undelivered or missed fire swaps the alarm for
/// a warning so it stands out among the routine's ordinary fires.
public struct RoutineNotice: View {
    let marker: RoutineMarkerEvent

    public init(marker: RoutineMarkerEvent) { self.marker = marker }

    public var body: some View {
        Label(marker.text, systemImage: marker.isUndelivered ? "exclamationmark.triangle" : "alarm")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
    }
}
