import SwiftUI
import MatronModels

/// What a project's page opens one tap down.
public enum ProjectSection: String, Hashable, Sendable, CaseIterable {
    case history, missions, files
}

/// The rows under "Needs you" on a project's page
/// (`TimelineFormat.waitingList`).
public struct ProjectWaitingList: Equatable, Sendable {
    public let rows: [TimelineItemRef]
    /// "and 2 more", while waiting items are counted but not listed.
    public let more: String?
    /// Whether "and N more" opens onto the rest.
    public let canExpand: Bool

    public init(rows: [TimelineItemRef], more: String?, canExpand: Bool) {
        self.rows = rows; self.more = more; self.canExpand = canExpand
    }
}

/// A project's page, kept light: its picture (no area without one), its
/// name with "···" beside it, one sentence on where it stands, what is
/// next, what waits on the user, then three rows that open the detail: the
/// weeks it moved in, its missions and its files. A row with nothing
/// behind it is dimmed and can't be opened. The page lists the newest
/// items waiting and counts the rest ("and 2 more"): that row lists them
/// all in place, once the host has them. A pure leaf: hosts pass the
/// page, its loaded picture and the openers, fill "···" with `menu`, and
/// provide the way back.
public struct ProjectSummaryView<MenuContent: View>: View {
    let page: TimelineProjectPage
    let image: Image?
    let pixelSize: CGSize?
    let allWaiting: [TimelineItemRef]?
    let onOpenItem: (String) -> Void
    let onOpenSection: (ProjectSection) -> Void
    let menu: MenuContent

    /// "and N more" was opened: every waiting item is listed.
    @State private var showsAllWaiting: Bool

    /// `pixelSize` is the picture's own size, when the host knows it.
    /// `allWaiting` is every item of the project waiting on the user, or
    /// nil until the host has them; `showsAllWaiting` starts the page with
    /// them listed.
    public init(page: TimelineProjectPage, image: Image?, pixelSize: CGSize?,
                allWaiting: [TimelineItemRef]? = nil, showsAllWaiting: Bool = false,
                onOpenItem: @escaping (String) -> Void, onOpenSection: @escaping (ProjectSection) -> Void,
                @ViewBuilder menu: () -> MenuContent) {
        self.page = page; self.image = image; self.pixelSize = pixelSize
        self.allWaiting = allWaiting
        self.onOpenItem = onOpenItem; self.onOpenSection = onOpenSection
        self.menu = menu()
        _showsAllWaiting = State(initialValue: showsAllWaiting)
    }

    private typealias M = ProjectPageMetrics

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TimelinePage.sectionSpacing) {
                picture
                words
                next
                waiting
                sections
            }
            .frame(maxWidth: M.readableWidth, alignment: .leading)
            .padding(TimelinePage.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("projects.summary")
    }

    // MARK: Picture and words

    @ViewBuilder private var picture: some View {
        if let media = page.media {
            let shape = RoundedRectangle(cornerRadius: M.pictureCorner, style: .continuous)
            TimelineMediaView(media: media, image: image, pixelSize: pixelSize)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.10)))
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(page.project.title).font(TimelinePage.titleFont)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                moreMenu
            }
            if let sentence = Self.words(page.sentence) {
                Text(MissionsDashboardFormat.statusPreviewText(sentence))
                    .font(M.sentenceFont).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("projects.summary.sentence")
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            menu
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 24)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        #if os(macOS)
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .accessibilityLabel("More")
        .accessibilityIdentifier("projects.summary.more")
    }

    @ViewBuilder private var next: some View {
        if let next = Self.words(page.next) {
            VStack(alignment: .leading, spacing: 8) {
                ProjectPageHeading(TimelineFormat.nextHeading)
                Text(MissionsDashboardFormat.statusPreviewText(next))
                    .font(M.rowFont).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("projects.summary.next")
            }
        }
    }

    // MARK: Needs you

    @ViewBuilder private var waiting: some View {
        let list = TimelineFormat.waitingList(page, all: allWaiting, expanded: showsAllWaiting)
        if !list.rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ProjectPageHeading(TimelineFormat.needsYouHeading)
                ForEach(list.rows, id: \.id) { item in
                    Button { onOpenItem(item.id) } label: { waitingRow(item) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("projects.summary.waiting.\(item.num)")
                }
                if let more = list.more { moreWaitingRow(more, opens: list.canExpand) }
            }
        }
    }

    /// "and 2 more": lists them in place when they are known, and until
    /// then only counts them.
    @ViewBuilder private func moreWaitingRow(_ more: String, opens: Bool) -> some View {
        let row = ProjectPageRow(mark: opens ? .opensInPlace : nil) { Text(more).foregroundStyle(.secondary) }
        if opens {
            Button { showsAllWaiting = true } label: { row }
                .buttonStyle(.plain)
                .accessibilityHint("Shows every item waiting for you")
                .accessibilityIdentifier("projects.summary.waiting.more")
        } else {
            row.accessibilityIdentifier("projects.summary.waiting.more")
        }
    }

    private func waitingRow(_ item: TimelineItemRef) -> some View {
        ProjectPageRow {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Color.red).frame(width: M.dotSize, height: M.dotSize)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(ProjectsFormat.oneLine(item.title)).foregroundStyle(Color.red).lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waiting for you: \(ProjectsFormat.oneLine(item.title))")
    }

    // MARK: Sections

    private var sections: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ProjectSection.allCases, id: \.self) { section in
                let isEmpty = TimelineFormat.sectionIsEmpty(section, page: page)
                Button { onOpenSection(section) } label: {
                    ProjectPageRow(detail: TimelineFormat.sectionCount(section, page: page)) {
                        Text(TimelineFormat.sectionTitle(section)).foregroundStyle(Color.primary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isEmpty)
                .opacity(isEmpty ? 0.45 : 1)
                .accessibilityIdentifier("projects.summary.\(section.rawValue)")
            }
        }
        .padding(.top, 4)
    }

    /// The text, or nil when it has no words.
    private static func words(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

public extension ProjectSummaryView where MenuContent == EmptyView {
    init(page: TimelineProjectPage, image: Image?, pixelSize: CGSize?,
         allWaiting: [TimelineItemRef]? = nil, showsAllWaiting: Bool = false,
         onOpenItem: @escaping (String) -> Void, onOpenSection: @escaping (ProjectSection) -> Void) {
        self.init(page: page, image: image, pixelSize: pixelSize, allWaiting: allWaiting,
                  showsAllWaiting: showsAllWaiting, onOpenItem: onOpenItem,
                  onOpenSection: onOpenSection) { EmptyView() }
    }
}

/// A small grey heading over part of a project's page: "NEXT", "NEEDS YOU".
struct ProjectPageHeading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A row of a project's page: its content, an optional count at the
/// trailing edge, and the mark for what a tap does.
struct ProjectPageRow<Content: View>: View {
    /// What the row does: opens a page, or lists more in place.
    enum Mark {
        case opensPage, opensInPlace

        var symbol: String { self == .opensPage ? "chevron.right" : "chevron.down" }
    }

    let detail: String?
    /// nil for a row that opens nothing.
    let mark: Mark?
    let content: Content

    init(detail: String? = nil, mark: Mark? = .opensPage, @ViewBuilder content: () -> Content) {
        self.detail = detail; self.mark = mark; self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            content
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(ProjectPageMetrics.detailFont.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            }
            if let mark {
                Image(systemName: mark.symbol).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .font(ProjectPageMetrics.rowFont)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// The sizes a project's page and its three sections share. The Mac names
/// its own: its text styles run ~3 pt smaller than iOS's.
enum ProjectPageMetrics {
    #if os(macOS)
    static let sentenceFont = Font.system(size: 18)
    static let rowFont = Font.system(size: 15)
    static let detailFont = Font.system(size: 13)
    static let tileNameFont = Font.system(size: 13)
    static let tileMetaFont = Font.system(size: 11)
    static let dotSize: CGFloat = 9
    #else
    static let sentenceFont = Font.title3
    static let rowFont = Font.body
    static let detailFont = Font.subheadline
    static let tileNameFont = Font.caption
    static let tileMetaFont = Font.caption2
    static let dotSize: CGFloat = 10
    #endif
    /// The page stops growing here, so lines stay readable on a wide window.
    static let readableWidth: CGFloat = 760
    static let pictureCorner: CGFloat = 12
    /// A week's picture in the history: a card's width, not the page's.
    static let historyPictureWidth: CGFloat = 448
}
