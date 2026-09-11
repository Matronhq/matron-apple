import SwiftUI

/// The Settings › Storage rows, shared by `DeviceSettingsView` (iOS) and
/// `MacDeviceSettingsView` (Mac). A leaf view over a plain model: it reads no
/// store and knows no `AppDependencies`, so it renders in a snapshot test
/// with no journal at all, and the two platform screens carry one `Section`
/// each instead of twenty duplicated lines.
///
/// `model == nil` is the in-flight state: `StoreDiagnostics.sizes` stats two
/// file groups and runs two `COUNT(*)`s, which on a large mirror is visibly
/// slow, so the section shows a spinner rather than zeros.
public struct StorageSettingsRows: View {
    public struct Model: Equatable, Sendable {
        public let journalBytes: Int64
        public let searchBytes: Int64
        public let events: Int
        public let conversations: Int
        /// Pre-formatted by the caller from `LaunchTimeline.summary(...)` —
        /// the timeline lives in `MatronModels` and the copy rule with it.
        public let launchText: String
        /// Pre-formatted by the caller from
        /// `StoreDiagnostics.lastMaintenanceText(_:now:)`.
        public let maintenanceText: String

        public init(journalBytes: Int64, searchBytes: Int64, events: Int,
                    conversations: Int, launchText: String, maintenanceText: String) {
            self.journalBytes = journalBytes
            self.searchBytes = searchBytes
            self.events = events
            self.conversations = conversations
            self.launchText = launchText
            self.maintenanceText = maintenanceText
        }
    }

    let model: Model?

    public init(model: Model?) { self.model = model }

    public var body: some View {
        if let model {
            LabeledContent("Journal store", value: Self.byteText(model.journalBytes))
            LabeledContent("Search index", value: Self.byteText(model.searchBytes))
            LabeledContent("Events / Conversations",
                           value: Self.countsText(events: model.events,
                                                  conversations: model.conversations))
            LabeledContent("This launch", value: model.launchText)
            LabeledContent("Last maintenance", value: model.maintenanceText)
        } else {
            HStack {
                Text("Journal store")
                Spacer()
                ProgressView()
            }
        }
    }

    /// `ByteCountFormatter` has no `.locale` override — it always renders
    /// the decimal point through the *current* locale ("1.5 MB" under
    /// en_US, "1,5 MB" under fr_FR), which would put a comma *decimal*
    /// point in this row right next to `countsText`'s comma *grouping*
    /// separator: the same ambiguity `countsText` was pinned to avoid,
    /// reintroduced one row down. So the numeric part goes through the
    /// same pinned `NumberFormatter` `countsText` uses; only the
    /// KB/MB/GB threshold math is hand-rolled (decimal, 1000-based,
    /// matching `ByteCountFormatter`'s old `.file` count style).
    private static let byteNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.roundingMode = .halfUp
        return formatter
    }()

    /// Static and pure so the copy is testable without rendering.
    ///
    /// Below 1 KB: the raw byte count ("0 B", "500 B"). At or above 1 KB:
    /// the value in the largest whole unit that keeps the leading digit
    /// non-zero (KB below 1 MB, MB below 1 GB, GB at and above), rounded to
    /// one decimal place with the trailing ".0" dropped when the rounded
    /// value is a whole number — so an exact-MB fixture like `440_000_000`
    /// still renders "440 MB", not "440.0 MB".
    public static func byteText(_ bytes: Int64) -> String {
        let (divisor, suffix): (Double, String)
        switch bytes {
        case 1_000_000_000...:
            (divisor, suffix) = (1_000_000_000, "GB")
        case 1_000_000..<1_000_000_000:
            (divisor, suffix) = (1_000_000, "MB")
        case 1_000..<1_000_000:
            (divisor, suffix) = (1_000, "KB")
        default:
            return "\(bytes) B"
        }
        let value = Double(bytes) / divisor
        let text = byteNumberFormatter.string(from: NSNumber(value: value)) ?? String(bytes)
        return "\(text) \(suffix)"
    }

    /// `457,102 / 6,214`. The separator is pinned: these are diagnostic
    /// numbers read back to us in bug reports, and a grouping separator that
    /// changes with the device's region makes them ambiguous (and makes any
    /// test of this function locale-dependent).
    ///
    /// Deliberately a `NumberFormatter` with an explicit `groupingSeparator`
    /// rather than `IntegerFormatStyle<Int>().locale(en_US_POSIX)`: ICU's
    /// POSIX locale data carries no grouping separator at all, so that
    /// formatter renders "457102", not "457,102" — pinning the *locale*
    /// doesn't pin the *separator*. Forcing `usesGroupingSeparator` with an
    /// explicit `groupingSeparator` does.
    public static func countsText(events: Int, conversations: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        func text(_ value: Int) -> String {
            formatter.string(from: NSNumber(value: value)) ?? String(value)
        }
        return "\(text(events)) / \(text(conversations))"
    }
}
