import SwiftUI

/// Timeline card for a bridge subtask indicator (`🔀 Subtask: <label>`)
/// that resolved to a child sub-chat conversation. Replaces the plain text
/// message with a tappable entry — branch icon, the subagent's label, its
/// running/finished state, and a chevron affordance (spec
/// 2026-07-15-subagent-subchats §"Task tool cards … become tappable
/// entries"). The card is purely visual: the call site wraps it in a
/// `NavigationLink` (iOS) or `Button` (Mac) that opens the child.
public struct SubtaskLinkCard: View {
    let title: String
    let isRunning: Bool

    public init(title: String, isRunning: Bool) {
        self.title = title
        self.isRunning = isRunning
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.body)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(isRunning ? "Subagent · running" : "Subagent · finished")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: MessageBubbleMetrics.maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open subagent \(title), \(isRunning ? "running" : "finished")")
    }
}
