import SwiftUI

/// Thin labelled progress strip for attachment uploads, rendered by both
/// composers above the input while a send's upload is in flight. Exists
/// because a slow uplink turns a multi-MB screenshot into many seconds of
/// dead air — a determinate bar plus a percentage is the difference
/// between "working" and "frozen". Takes plain values (label + fraction)
/// so this target stays free of any view-model dependency.
public struct UploadProgressBar: View {
    private let label: String
    private let fraction: Double

    public init(label: String, fraction: Double) {
        self.label = label
        self.fraction = fraction
    }

    public var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(.linear)
            // Middle truncation, NOT `.fixedSize()`: a single-attachment
            // label carries the filename, and pasted photos get UUID temp
            // names wider than the screen — fixedSize made the row (and the
            // whole chat column) stretch past the display edge for the
            // duration of the upload. Truncating the middle keeps both the
            // extension and the trailing percent visible.
            Text("\(label) \(Int((min(max(fraction, 0), 1)) * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(Int(min(max(fraction, 0), 1) * 100)) percent uploaded")
    }
}
