import SwiftUI
import MatronModels

/// The Search page, shared by iPhone and Mac: one field that searches
/// everything, chips that narrow it to one kind, and the sections —
/// a number's "Go to" row, Conversations, Items, Missions, Projects,
/// Memories, then Messages. A pure leaf view: `GlobalSearchViewModel`
/// builds the `GlobalSearchPage`, and the host opens what a row leads to.
public struct GlobalSearchView: View {
    @Binding var text: String
    @Binding var filter: GlobalSearchFilter
    let page: GlobalSearchPage
    /// Draws the page's own field (Mac). iPhone hosts put the system
    /// search field on the page instead (`.searchable`).
    let showsField: Bool
    /// Return in the field, or a tap on the "Go to" row: opens the number.
    let onSubmit: () -> Void
    let onOpen: (GlobalSearchTarget) -> Void

    @FocusState private var fieldFocused: Bool

    public init(text: Binding<String>, filter: Binding<GlobalSearchFilter>, page: GlobalSearchPage,
                showsField: Bool = true, onSubmit: @escaping () -> Void,
                onOpen: @escaping (GlobalSearchTarget) -> Void) {
        _text = text; _filter = filter
        self.page = page; self.showsField = showsField; self.onSubmit = onSubmit; self.onOpen = onOpen
    }

    public static let placeholder = "Search conversations, items, missions, memories…"
    public static let emptyTitle = "Search everything"
    public static let emptyHint = "Conversations, items, missions, projects, memories and messages. Type a number to go straight to it."
    public static let failedMessage = "Search is unavailable right now."

    public var body: some View {
        VStack(spacing: 0) {
            if showsField {
                field
                    .padding(.horizontal)
                    .padding(.top, 10)
            }
            chips
            Divider()
            content
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(Self.placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit(onSubmit)
                .accessibilityLabel("Search everything")
                .accessibilityIdentifier("search.field")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
        .onAppear { fieldFocused = true }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(GlobalSearchFilter.allCases) { chip in
                    let selected = filter == chip
                    Button { filter = chip } label: {
                        Text(chip.title)
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18)
                                                                : Color.secondary.opacity(0.1)))
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("search.filter.\(chip.rawValue)")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        if page.status == .empty {
            ContentUnavailableView(Self.emptyTitle, systemImage: "magnifyingglass",
                                   description: Text(Self.emptyHint))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                sections
                statusSection
            }
        }
    }

    @ViewBuilder
    private var sections: some View {
        if filter == .all, let number = page.number {
            Section("Go to") {
                row(icon: "number", title: Text(number.label), detail: number.note.map { Text($0) }, why: nil,
                    action: number.canOpen ? onSubmit : nil)
                    .accessibilityIdentifier("search.number-hit")
            }
        }
        if filter.shows(.conversations), !page.conversations.isEmpty {
            Section("Conversations") {
                ForEach(page.conversations) { conversation in
                    row(icon: "bubble.left.and.bubble.right", title: Text(conversation.title),
                        detail: conversation.subtitle.map { Text($0) }, why: nil,
                        action: { onOpen(.conversation(conversation.id)) })
                }
            }
        }
        ForEach(GlobalSearchResult.Kind.allCases, id: \.self) { kind in
            let rows = page.results(kind)
            if filter.shows(GlobalSearchFilter(kind)), !rows.isEmpty {
                Section(Self.sectionTitle(kind)) {
                    ForEach(rows, id: \.rowID) { result in
                        resultRow(result)
                    }
                }
            }
        }
        if filter.shows(.messages), !page.chats.isEmpty {
            Section("Messages") {
                ForEach(page.chats, id: \.convoID) { chat in
                    row(icon: "text.bubble", title: Text(chat.label), detail: Self.marked(chat.top.excerpt), why: nil,
                        action: { onOpen(.message(convoID: chat.convoID, seq: chat.top.seq)) })
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch page.status {
        case .failed:
            Section { Text(Self.failedMessage).foregroundStyle(.secondary) }
        case .searching:
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                }
                .foregroundStyle(.secondary)
            }
        case .done, .empty:
            if page.isEmptyResult {
                Section { Text("Nothing matches “\(page.query)”.").foregroundStyle(.secondary) }
            }
        }
    }

    private func resultRow(_ result: GlobalSearchResult) -> some View {
        // One the journal sent without a number has nowhere to open.
        var action: (() -> Void)?
        if let target = result.target {
            action = { onOpen(target) }
        }
        return row(icon: Self.symbol(result.kind), title: Text(result.label),
                   detail: result.detail.map { Self.marked($0) }, why: result.whyLabel, action: action)
    }

    private func row(icon: String, title: Text, detail: Text?, why: String?,
                     action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    title.lineLimit(2)
                    if let detail {
                        detail.font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if let why {
                    Text(why)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    static func sectionTitle(_ kind: GlobalSearchResult.Kind) -> String {
        switch kind {
        case .item: return "Items"
        case .mission: return "Missions"
        case .project: return "Projects"
        case .memory: return "Memories"
        }
    }

    static func symbol(_ kind: GlobalSearchResult.Kind) -> String {
        switch kind {
        case .item: return "tray"
        case .mission: return "flag"
        case .project: return ProjectGlyph.symbol
        case .memory: return "brain"
        }
    }

    /// A snippet with its `**…**` matches drawn bold in the accent colour.
    static func marked(_ snippet: String) -> Text {
        GlobalSearchText.markedRuns(snippet).reduce(Text(verbatim: "")) { line, run in
            line + (run.isMatch ? Text(run.text).bold().foregroundColor(.accentColor) : Text(run.text))
        }
    }
}
