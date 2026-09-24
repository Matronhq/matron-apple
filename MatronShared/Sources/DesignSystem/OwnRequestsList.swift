import SwiftUI
import MatronModels

/// The Coordinator's "Your requests" (tracker #2864 B): the messages the
/// user sent in the Coordinator chat, newest first, each a one-line preview
/// with its relative time. Shared by the Mac panel's popover and the iOS
/// sheet; a dumb projection — the caller loads `requests` (nil while
/// loading) and handles the pick.
public struct OwnRequestsList: View {
    let requests: [OwnMessageSummary]?
    let onSelect: (OwnMessageSummary) -> Void

    public init(requests: [OwnMessageSummary]?, onSelect: @escaping (OwnMessageSummary) -> Void) {
        self.requests = requests
        self.onSelect = onSelect
    }

    public var body: some View {
        if let requests {
            if requests.isEmpty {
                ContentUnavailableView("No requests yet", systemImage: "text.bubble",
                                       description: Text("Messages you send the Coordinator appear here."))
            } else {
                list(requests)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ requests: [OwnMessageSummary]) -> some View {
        List(requests) { request in
            Button { onSelect(request) } label: { OwnRequestRow(request: request) }
                .buttonStyle(.plain)
        }
        .listStyle(.plain)
    }
}

/// One "Your requests" row: preview over its relative time.
struct OwnRequestRow: View {
    let request: OwnMessageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(request.preview())
                .lineLimit(2)
                .truncationMode(.tail)
                .foregroundStyle(Color.primary)
            Text(request.date, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Jumps to this message")
    }
}
