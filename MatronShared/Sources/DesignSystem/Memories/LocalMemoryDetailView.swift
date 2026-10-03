import SwiftUI
import MatronModels

/// One file from a box — a Claude Code memory or a CLAUDE.md — read-only:
/// where it lives, its text, and whether a journal memory already says the
/// same. A pure leaf; the host loads the text and passes it in.
public struct LocalMemoryDetailView: View {
    public static let noOverlapText = "No journal memory shares words with this one."
    public static let readOnlyNote = "This is a file on that box. An agent there edits it."

    let model: LocalMemoryDetail
    let onRetry: () -> Void
    /// Opens the journal memory the overlap line names, where the host can.
    let onOpenJournalMemory: ((String) -> Void)?

    public init(model: LocalMemoryDetail, onRetry: @escaping () -> Void, onOpenJournalMemory: ((String) -> Void)? = nil) {
        self.model = model; self.onRetry = onRetry; self.onOpenJournalMemory = onOpenJournalMemory
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("On \(model.boxName) · Read-only")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Text(model.title).font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.metaLine(model))
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                text
                if model.isMemory {
                    Divider()
                    overlap
                }
                Text(Self.readOnlyNote).font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        .background(MatronTimelineBackground())
        #endif
    }

    @ViewBuilder
    private var text: some View {
        switch model.text {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading from \(model.boxName)…").foregroundStyle(.secondary)
            }
            .font(.subheadline)
        case .loaded(let text):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("This file is empty.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                MarkdownText(Self.withoutFrontmatter(text))
                    .accessibilityIdentifier("memories.local.body")
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.subheadline).foregroundStyle(.orange)
                Button("Try again", action: onRetry)
            }
        }
    }

    private var overlap: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Looks like a journal memory?")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            if let name = model.overlap {
                if let onOpenJournalMemory {
                    Button { onOpenJournalMemory(name) } label: { OverlapTag(name: name) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens that journal memory")
                } else {
                    OverlapTag(name: name)
                }
                Text("Its description shares words with this one. Check whether both are needed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(Self.noOverlapText).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// "yearbook-app · ~/.claude/…/x.md · project · modified 28 Sep 2026".
    static func metaLine(_ model: LocalMemoryDetail) -> String {
        var parts = [model.repoTitle, model.shortPath]
        if let type = model.type { parts.append(type) }
        if let modifiedAt = model.modifiedAt, modifiedAt.timeIntervalSince1970 > 0 {
            parts.append("modified " + modifiedAt.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A memory file opens with a YAML frontmatter block (`name`,
    /// `description`, `metadata`), which the header already shows and which
    /// Markdown would draw as a rule and a heading. Only a block that both
    /// opens the file and is closed is removed.
    static func withoutFrontmatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return text }
        let rest = lines[(close + 1)...].joined(separator: "\n")
        let trimmed = rest.drop(while: { $0 == "\n" || $0 == "\r" })
        return trimmed.isEmpty ? text : String(trimmed)
    }
}
