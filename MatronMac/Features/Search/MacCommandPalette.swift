import SwiftUI
import MatronChat
import MatronModels
import MatronSearch
import MatronViewModels
import MatronDesignSystem

/// Go ▸ Search Everything… (⌘K): one field over conversations, items,
/// missions, projects and message text, results grouped by kind. The arrow
/// keys move the highlight, Return opens it, Escape closes. A sheet, like
/// Go to Number, so it has somewhere to show with the sidebar collapsed.
struct MacCommandPalette: View {
    @Bindable var viewModel: CommandPaletteViewModel
    /// Opens a row; the host closes the palette.
    let onOpen: (CommandPaletteResult) -> Void
    let onCancel: () -> Void

    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    static let prompt = "Search conversations, items, missions, projects and messages"

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            resultsList
            Divider()
            footer
        }
        .frame(width: 640, height: 460)
        .onAppear { fieldFocused = true }
        .task { await viewModel.load() }
        // Keyed on the query: a newer keystroke cancels the wait before
        // the journal is asked.
        .task(id: viewModel.query) { await viewModel.runSearch() }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField("Search", text: $viewModel.query, prompt: Text(Self.prompt))
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit(openSelected)
                .onKeyPress(.downArrow) { viewModel.moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { viewModel.moveSelection(by: -1); return .handled }
                .onKeyPress(.escape) { onCancel(); return .handled }
                .accessibilityIdentifier("palette.field")
            if viewModel.search.isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    ForEach(viewModel.sections) { section in
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(section.results) { result in
                            row(result)
                                .id(result.id)
                        }
                    }
                    if viewModel.showsNoResults {
                        Text(viewModel.emptyMessage)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: viewModel.selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "to move")
            hint("↩", "to open")
            hint("esc", "to close")
            Spacer()
            Text("Type a number to go to it")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 4)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            Text(text)
        }
    }

    private func openSelected() {
        guard let result = viewModel.selectedResult else { return }
        onOpen(result)
    }

    // MARK: Rows

    private func row(_ result: CommandPaletteResult) -> some View {
        let selected = viewModel.selectedID == result.id
        return Button { onOpen(result) } label: {
            rowContent(result)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { viewModel.select(result) } }
        .accessibilityIdentifier("palette.row.\(result.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func rowContent(_ result: CommandPaletteResult) -> some View {
        switch result {
        case .number(let hit):
            line(icon: "number", title: Text(hit.title ?? hit.heading),
                 detail: hit.heading, trailing: hit.cannotOpenReason)
        case .chat(let chat):
            let title = viewModel.search.hitTitle(for: chat.id)
            line(icon: "bubble.left.and.bubble.right",
                 title: SessionTagText.titleLine(title: title.title, boxLetter: title.boxLetter,
                                                 boxName: title.boxName, sessionShort: title.sessionShort,
                                                 roomBoxNames: title.roomBoxNames,
                                                 roomBoxShorts: title.roomBoxShorts, colorScheme: colorScheme),
                 detail: chat.snippet.isEmpty ? nil : chat.snippet, trailing: nil)
        case .item(let item):
            line(icon: Self.icon(for: item.kind), title: Text(item.title),
                 detail: "#\(item.num) · \(item.kind.rawValue.capitalized)",
                 trailing: item.state == .closed ? "Closed" : nil)
        case .mission(let mission):
            line(icon: "flag", title: Text(mission.title),
                 detail: "#\(mission.num)" + (mission.name.map { " · \($0)" } ?? ""),
                 trailing: mission.state == .closed ? "Closed" : nil)
        case .project(let project):
            line(icon: "folder", title: Text(project.title),
                 detail: "#\(project.num)", trailing: project.state == .closed ? "Closed" : nil)
        case .message(let group):
            let title = viewModel.search.hitTitle(for: group.roomID)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "text.bubble")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                SearchResultRow(hit: group.topHit, chatTitle: title.title,
                            sessionShort: title.sessionShort, boxLetter: title.boxLetter,
                            boxName: title.boxName, roomBoxNames: title.roomBoxNames,
                            roomBoxShorts: title.roomBoxShorts, subChatTitle: title.subChatTitle,
                            senderLabel: viewModel.search.senderLabel(for: group.topHit),
                            matchCount: group.count, onTap: { onOpen(result) })
            }
        }
    }

    private func line(icon: String, title: Text, detail: String?, trailing: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                title.lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    static func icon(for kind: ItemKind) -> String {
        switch kind {
        case .task: return "checklist"
        case .question: return "questionmark.bubble"
        case .decision: return "checkmark.seal"
        case .notice: return "bell"
        }
    }
}
