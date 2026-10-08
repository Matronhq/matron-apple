import SwiftUI
import MatronModels

/// The Memories list's "On your boxes" section: each box's own Claude Code
/// memories, read-only, grouped by repo then box. A run of `List` rows —
/// `MemoriesListView` places it under the journal's memories.
///
/// A pure leaf: the host builds `LocalMemoriesSection` from
/// `LocalMemoriesViewModel` and handles the taps.
public struct LocalMemoriesSectionRows: View {
    public struct Actions {
        let toggleGroup: (String) -> Void
        let selectBox: (_ boxID: Int64, _ groupID: String) -> Void
        let showAll: (String) -> Void
        let open: (LocalMemoryRef) -> Void

        public init(toggleGroup: @escaping (String) -> Void,
                    selectBox: @escaping (_ boxID: Int64, _ groupID: String) -> Void,
                    showAll: @escaping (String) -> Void,
                    open: @escaping (LocalMemoryRef) -> Void) {
            self.toggleGroup = toggleGroup; self.selectBox = selectBox; self.showAll = showAll; self.open = open
        }
    }

    public static let title = "On your boxes"
    public static let caption = "Each box's own Claude Code memories and CLAUDE.md files, by repo. Read-only. Boxes that are online are asked when this screen opens."
    public static let footnote = "Journal memories are edited here. Box memories are files on that box: an agent there edits them."

    let section: LocalMemoriesSection
    let actions: Actions

    public init(section: LocalMemoriesSection, actions: Actions) {
        self.section = section; self.actions = actions
    }

    public var body: some View {
        header
        if let loadError = section.loadError {
            note(loadError, color: .orange)
        }
        ForEach(section.groups) { group in
            groupHeader(group)
            if group.isExpanded {
                chips(group)
                ForEach(group.rows) { row in memoryRow(row) }
                if group.hiddenCount > 0 { showMore(group) }
            }
        }
        if let emptyNote = section.emptyNote {
            note(emptyNote, color: .secondary)
        }
        footer
    }

    static func waitingLine(_ names: [String]) -> String {
        "Waiting for \(names.joined(separator: ", "))…"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Self.title).font(.headline)
                if section.isLoading || !section.hasLoaded {
                    ProgressView().controlSize(.small).accessibilityLabel("Asking your boxes")
                }
            }
            Text(Self.caption).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !section.loadingBoxes.isEmpty {
                Text(Self.waitingLine(section.loadingBoxes)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 12)
        .plainSectionRow()
        .accessibilityIdentifier("memories.local.header")
    }

    private func groupHeader(_ group: LocalMemoriesSection.Group) -> some View {
        Button { actions.toggleGroup(group.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title).font(.body.weight(.semibold)).lineLimit(1)
                    if let path = group.path {
                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Text(group.countLine).font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .plainSectionRow()
        .accessibilityIdentifier("memories.local.group.\(group.title)")
        .accessibilityHint(group.isExpanded ? "Collapses this repo" : "Expands this repo")
    }

    private func chips(_ group: LocalMemoriesSection.Group) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(group.chips) { chip in
                    Button { actions.selectBox(chip.boxID, group.id) } label: {
                        Text("\(chip.name) · \(chip.count)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .foregroundStyle(chip.isSelected ? Color.white : Color.primary)
                            .background(chip.isSelected ? Color.accentColor : Color.secondary.opacity(0.15),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(chip.name), \(chip.count)")
                    .accessibilityAddTraits(chip.isSelected ? .isSelected : [])
                    .accessibilityIdentifier("memories.local.chip.\(group.title).\(chip.name)")
                }
            }
            .padding(.leading, 18)
        }
        .plainSectionRow()
    }

    private func memoryRow(_ row: LocalMemoriesSection.Row) -> some View {
        Button { actions.open(row.ref) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.subheadline.weight(.medium)).lineLimit(2)
                if !row.summary.isEmpty {
                    Text(MemoryRowView.oneLine(row.summary)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let overlap = row.overlap { OverlapTag(name: overlap) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 18)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .accessibilityIdentifier("memories.local.row.\(row.title)")
        #if os(macOS)
        .listRowBackground(row.isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .macInboxRow(hideTopSeparator: false)
        #else
        .listRowBackground(Color.clear)
        #endif
    }

    private func showMore(_ group: LocalMemoriesSection.Group) -> some View {
        Button { actions.showAll(group.id) } label: {
            Text("Show \(group.hiddenCount) more\(group.selectedBoxName.map { " on \($0)" } ?? "")")
                .font(.caption.weight(.medium))
                .padding(.leading, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .plainSectionRow()
        .accessibilityIdentifier("memories.local.more.\(group.title)")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(section.boxNotes, id: \.self) { Text($0) }
            Text(Self.footnote)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
        .plainSectionRow()
        .accessibilityIdentifier("memories.local.footer")
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text).font(.caption).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .plainSectionRow()
    }
}

/// The yellow "≈ name" tag: this box memory's words overlap that journal
/// memory's.
public struct OverlapTag: View {
    let name: String

    public init(name: String) { self.name = name }

    public var body: some View {
        Text("≈ \(name)")
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(Color(red: 0.45, green: 0.30, blue: 0.0))
            .background(Color(red: 1.0, green: 0.92, blue: 0.62), in: Capsule())
            .accessibilityLabel("Looks like the journal memory \(name)")
    }
}

private extension View {
    /// A section row that is not a memory: no separator, no fill, and on
    /// the Mac the same horizontal inset as the caption row above.
    func plainSectionRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            #if os(macOS)
            .padding(.horizontal, 4)
            #endif
    }
}
