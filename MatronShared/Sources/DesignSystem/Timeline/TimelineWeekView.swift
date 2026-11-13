import SwiftUI
import MatronModels

/// One week of the Projects timeline: the title and dates, the layout
/// switch, then a card (or, in list layout, a compact row) for each project
/// that moved: the week's stories first, then the other projects, most
/// active first, paged in as the page reaches its end (`extras`, with a
/// loading row or a Retry at the end). Cards go two to a row from 700 pt,
/// one below. From a journal that does not page the other projects
/// (`extras` nil or unsupported) the page shows eight cards at most and one
/// quiet line for the others, which opens into a plain list of them. A week
/// where nothing moved says so in a line. `footer` follows inside the
/// scroll (the iPhone puts the "Worth a look" rows there). A pure leaf:
/// hosts pass the week, its paged projects, the loaded pictures and their
/// pixel sizes by blob id, and the actions. The layout is kept per device
/// (`TimelineWeekLayout.storageKey`).
public struct TimelineWeekView<Footer: View>: View {
    let week: TimelineWeek
    let extras: TimelineWeekExtras?
    let now: Date
    let images: [String: Image]
    let sizes: [String: CGSize]
    let onOpenProject: (String) -> Void
    let onLoadMore: () -> Void
    let footer: Footer

    @State private var showsAlso = false
    @AppStorage private var layout: TimelineWeekLayout

    /// `layoutStore` nil keeps the layout in the standard defaults.
    public init(week: TimelineWeek, extras: TimelineWeekExtras? = nil, now: Date, images: [String: Image],
                sizes: [String: CGSize] = [:], layoutStore: UserDefaults? = nil,
                onOpenProject: @escaping (String) -> Void, onLoadMore: @escaping () -> Void = {},
                @ViewBuilder footer: () -> Footer) {
        self.week = week; self.extras = extras; self.now = now; self.images = images; self.sizes = sizes
        self.onOpenProject = onOpenProject; self.onLoadMore = onLoadMore; self.footer = footer()
        _layout = AppStorage(wrappedValue: TimelineWeekLayout.default, TimelineWeekLayout.storageKey, store: layoutStore)
    }

    /// Two cards to a row on a wide page, one on a narrow one.
    static func columnCount(pageWidth: CGFloat) -> Int {
        pageWidth >= TimelinePage.wideWidth ? 2 : 1
    }

    /// The other projects are paged in rather than counted in a line.
    private var pagesProjects: Bool { extras.map { $0.status != .unsupported } ?? false }

    public var body: some View {
        // GeometryReader outside the scroll: the width is there on the first
        // layout, so a wide window never draws one column first.
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: TimelinePage.sectionSpacing) {
                    top
                    if TimelineFormat.movedNothing(week) {
                        Text(TimelineFormat.nothingMoved).font(TimelinePage.ledeFont).foregroundStyle(.secondary)
                            .accessibilityIdentifier("timeline.week.empty")
                    }
                    let stories = TimelineFormat.cards(week, extras: extras)
                    if !stories.isEmpty || pagesProjects {
                        switch layout {
                        case .tiles: cards(stories, columns: Self.columnCount(pageWidth: geo.size.width))
                        case .list: rows(stories)
                        }
                    }
                    if !pagesProjects { also }
                    footer
                }
                .padding(TimelinePage.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id(week.week)
    }

    /// The title and dates, and the layout switch beside them where it
    /// fits, else under them.
    @ViewBuilder private var top: some View {
        if TimelineFormat.movedNothing(week) {
            header
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    header
                    Spacer(minLength: 12)
                    layoutSwitch
                }
                VStack(alignment: .leading, spacing: 12) {
                    header
                    layoutSwitch
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(TimelineFormat.pageTitle(week, now: now)).font(TimelinePage.titleFont)
                .accessibilityAddTraits(.isHeader)
            if let dates = TimelineFormat.pageDates(week, now: now) {
                Text(dates).font(TimelinePage.datesFont).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var layoutSwitch: some View {
        Picker(TimelineFormat.layoutSwitchLabel, selection: $layout) {
            ForEach(TimelineWeekLayout.allCases, id: \.self) { choice in
                Label(choice.title, systemImage: choice.symbol).labelStyle(.titleOnly).tag(choice)
                    .accessibilityIdentifier("timeline.week.layout.\(choice.rawValue)")
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(TimelineFormat.layoutSwitchLabel)
        .accessibilityIdentifier("timeline.week.layout")
    }

    private func cards(_ stories: [TimelineStory], columns: Int) -> some View {
        let rows = stride(from: 0, to: stories.count, by: columns).map {
            Array(stories[$0..<min($0 + columns, stories.count)])
        }
        // Lazy: a busy week pages in hundreds of cards.
        return LazyVStack(alignment: .leading, spacing: TimelinePage.cardSpacing) {
            ForEach(rows.indices, id: \.self) { index in
                // Cards in a row share the tallest one's height.
                HStack(alignment: .top, spacing: TimelinePage.cardSpacing) {
                    // By position: an older journal may send two stories for one project.
                    ForEach(Array(rows[index].enumerated()), id: \.offset) { _, story in card(story) }
                    if rows[index].count < columns { Color.clear.frame(maxWidth: .infinity) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if pagesProjects { pageEnd }
        }
    }

    private func card(_ story: TimelineStory) -> some View {
        TimelineStoryCard(story: story, image: story.media.flatMap { images[$0.blobID] },
                          pixelSize: story.media.flatMap { sizes[$0.blobID] })
            .onTapGesture { onOpenProject(story.project.id) }
            .accessibilityAction(named: Text("Open project")) { onOpenProject(story.project.id) }
    }

    private func rows(_ stories: [TimelineStory]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            // By position, as the cards are.
            ForEach(Array(stories.enumerated()), id: \.offset) { index, story in
                if index > 0 { Divider().padding(.leading, TimelineWeekRow.thumbnailSize + 12) }
                Button { onOpenProject(story.project.id) } label: {
                    TimelineWeekRow(story: story, image: story.media.flatMap { images[$0.blobID] })
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(TimelineFormat.rowLabel(story))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onOpenProject(story.project.id) }
                .accessibilityIdentifier("timeline.week.row.\(story.project.num)")
            }
            if pagesProjects { pageEnd.padding(.top, 8) }
        }
    }

    /// The end of the paged projects: a loading row (reaching it asks for
    /// the next page), or Retry when the last read failed. It is the last
    /// child of the lazy stack, so it appears only when scrolled near: in
    /// the plain stack round it, it would appear at once and read every page.
    @ViewBuilder private var pageEnd: some View {
        if let extras {
            switch extras.status {
            case .more, .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(TimelineFormat.loadingMoreProjects).font(TimelinePage.lineFont).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("timeline.week.loading")
                // A new row for each paging state, asking on appear: the lazy
                // stack builds it only near the screen, so a page that lands
                // with the end still in view (too short to scroll) asks for
                // the next, and one that pushed the end away does not.
                .id("\(extras.week) \(extras.projects.count) \(extras.status)")
                .onAppear {
                    if extras.status == .more { onLoadMore() }
                }
            case .failed:
                HStack(spacing: 12) {
                    Text(TimelineFormat.moreProjectsFailed).font(TimelinePage.lineFont).foregroundStyle(.secondary)
                    Button(TimelineFormat.retry, action: onLoadMore)
                        .accessibilityIdentifier("timeline.week.retry")
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            case .done, .unsupported:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var also: some View {
        let projects = TimelineFormat.alsoMovedProjects(week)
        if let line = TimelineFormat.alsoMoved(projects.count) {
            VStack(alignment: .leading, spacing: 10) {
                Button { showsAlso.toggle() } label: {
                    Text(line + TimelineFormat.opensMark).font(TimelinePage.lineFont)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(line)
                .accessibilityIdentifier("timeline.week.also")
                if showsAlso {
                    VStack(alignment: .leading, spacing: 8) {
                        // By position, as the cards are.
                        ForEach(Array(projects.enumerated()), id: \.offset) { _, project in
                            Button { onOpenProject(project.id) } label: {
                                Text(project.title).font(TimelinePage.lineFont).foregroundStyle(Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 14)
                }
            }
        }
    }
}

public extension TimelineWeekView where Footer == EmptyView {
    init(week: TimelineWeek, extras: TimelineWeekExtras? = nil, now: Date, images: [String: Image],
         sizes: [String: CGSize] = [:], layoutStore: UserDefaults? = nil,
         onOpenProject: @escaping (String) -> Void, onLoadMore: @escaping () -> Void = {}) {
        self.init(week: week, extras: extras, now: now, images: images, sizes: sizes, layoutStore: layoutStore,
                  onOpenProject: onOpenProject, onLoadMore: onLoadMore) { EmptyView() }
    }
}

/// The metrics the timeline's pages share: a week, and the three lists.
enum TimelinePage {
    /// Page widths from here up are wide: story cards two to a row, a list
    /// row's chart beside it.
    static let wideWidth: CGFloat = 700

    #if os(macOS)
    static let titleFont = Font.system(size: 28, weight: .bold)
    static let datesFont = Font.system(size: 14)
    static let ledeFont = Font.system(size: 18)
    static let lineFont = Font.system(size: 14)
    static let padding = EdgeInsets(top: 28, leading: 32, bottom: 32, trailing: 32)
    static let cardSpacing: CGFloat = 20
    static let sectionSpacing: CGFloat = 24
    #else
    static let titleFont = Font.largeTitle.bold()
    static let datesFont = Font.subheadline
    static let ledeFont = Font.body
    static let lineFont = Font.subheadline
    static let padding = EdgeInsets(top: 16, leading: 16, bottom: 24, trailing: 16)
    static let cardSpacing: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
    #endif
}
