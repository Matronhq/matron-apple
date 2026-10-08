import SwiftUI
import MatronModels

/// The briefing card's and reader's words, pure so each is a plain test.
public enum BriefingFormat {
    public static let title = "Latest briefing"
    public static let refreshLabel = "Ask the Coordinator for a new briefing"
    public static let refreshing = "Refreshing…"
    public static let notAnswered = "The Coordinator hasn't answered."
    public static let tryAgain = "Try again"
    public static let noBriefing = "No briefing yet"
    public static let askForOne = "Ask for one"
    public static let openInChat = "Open in chat"

    /// "5 minutes ago", "2 hours ago", "just now" under a minute. A date
    /// ahead of `now` (another device's clock) reads as now.
    public static func age(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "Latest briefing · 5 minutes ago"; just the title with no briefing.
    public static func heading(createdAt: Date?, now: Date) -> String {
        guard let createdAt else { return title }
        return "\(title) · \(age(createdAt, now: now))"
    }

    /// The reader's date line: "Saturday, 4 October 2026 at 09:12 · 5 minutes ago".
    public static func readerDateLine(_ createdAt: Date, now: Date) -> String {
        "\(createdAt.formatted(date: .complete, time: .shortened)) · \(age(createdAt, now: now))"
    }

    /// The card's preview, as on web (`briefingPreviewLines`): the first
    /// `count` non-blank lines of the markdown, each reduced to plain text
    /// (block syntax — headings, quotes, list markers, rules, fences, table
    /// rules — and inline markers dropped, a link's text kept) and shown on
    /// its own line, so a heading is line 1 and the first body line line 2.
    public static func previewLines(_ body: String, count: Int = 2) -> [String] {
        let ruleCharacters: Set<Character> = ["-", "*", "_", "=", "|", ":", " "]
        var parts: [String] = []
        for raw in body.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { continue }
            // Empty lines, `---`, `***`, setext underlines and table rules.
            if line.allSatisfy({ ruleCharacters.contains($0) }) { continue }
            while line.hasPrefix("#") || line.hasPrefix(">") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            for marker in ["- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "+ "] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count))
                break
            }
            let digits = line.prefix { $0.isNumber }
            if !digits.isEmpty {
                let rest = line.dropFirst(digits.count)
                if rest.hasPrefix(". ") || rest.hasPrefix(") ") { line = String(rest.dropFirst(2)) }
            }
            line = plainText(line).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !line.isEmpty { parts.append(line) }
            if parts.count == count { break }
        }
        return parts
    }

    /// One line's inline markdown as the words it shows.
    private static func plainText(_ line: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let text = try? AttributedString(markdown: line, options: options) else { return line }
        return String(text.characters)
    }
}

/// "Latest briefing" at the top of the Projects home (both apps): the
/// Coordinator's newest briefing as a two-line preview with its age, and a
/// button asking the Coordinator for a new one. Tapping the card opens the
/// briefing in full. A pure leaf: hosts map `LatestBriefingStore` into
/// `BriefingCardModel`.
public struct LatestBriefingCard: View {
    let model: BriefingCardModel
    let now: Date
    let onOpen: () -> Void
    let onRefresh: () -> Void

    public init(model: BriefingCardModel, now: Date, onOpen: @escaping () -> Void, onRefresh: @escaping () -> Void) {
        self.model = model; self.now = now; self.onOpen = onOpen; self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(DashboardCardChrome())
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { open() }
        // As `MissionCardView`: the container holds its own buttons, so it
        // takes a named action rather than a button trait it can't carry.
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Open briefing")) { open() }
        .accessibilityIdentifier("projects.briefing")
    }

    private func open() {
        if model.hasBriefing { onOpen() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Label {
                Text(BriefingFormat.heading(createdAt: model.createdAt, now: now))
            } icon: {
                Image(systemName: "newspaper")
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(!model.canRefresh)
                .help(BriefingFormat.refreshLabel)
                .accessibilityLabel(BriefingFormat.refreshLabel)
                .accessibilityIdentifier("projects.briefing.refresh")
        }
    }

    @ViewBuilder private var content: some View {
        if model.hasBriefing {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(BriefingFormat.previewLines(model.body).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(BriefingFormat.noBriefing).font(.subheadline).foregroundStyle(.secondary)
                if model.state == .idle {
                    Button(BriefingFormat.askForOne, action: onRefresh)
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                        .disabled(!model.canRefresh)
                        .accessibilityIdentifier("projects.briefing.askForOne")
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch model.state {
        case .refreshing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(BriefingFormat.refreshing)
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        case .failed:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(BriefingFormat.notAnswered).foregroundStyle(.secondary)
                Button(BriefingFormat.tryAgain, action: onRefresh)
                    .buttonStyle(.borderless)
                    .disabled(!model.canRefresh)
                    .accessibilityIdentifier("projects.briefing.retry")
            }
            .font(.caption)
        case .idle:
            EmptyView()
        }
        if let notice = model.notice {
            Text(notice).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The briefing in full: its date, the markdown with working links, and
/// "Open in chat". Hosts wrap it in their sheet chrome (a title and Done)
/// and install the link openers — `matron://` links work only under a host
/// that does (see `MarkdownText`).
public struct BriefingReaderView: View {
    let markdown: String
    let createdAt: Date
    let now: Date?
    let onOpenInChat: (() -> Void)?

    public init(markdown: String, createdAt: Date, now: Date? = nil, onOpenInChat: (() -> Void)? = nil) {
        self.markdown = markdown; self.createdAt = createdAt; self.now = now; self.onOpenInChat = onOpenInChat
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ticking { now in
                    Text(BriefingFormat.readerDateLine(createdAt, now: now))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                MarkdownText(markdown)
                if let onOpenInChat {
                    Button(action: onOpenInChat) {
                        Label(BriefingFormat.openInChat, systemImage: "bubble.left.and.bubble.right")
                    }
                    .accessibilityIdentifier("briefing.openInChat")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func ticking<Content: View>(@ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        if let now { content(now) } else { TimelineView(.periodic(from: .now, by: 60)) { content($0.date) } }
    }
}
