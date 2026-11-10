import SwiftUI
import MatronModels

/// One week of the Projects timeline: the title and dates, a card for each
/// project's week (eight at most; two columns from 700 pt, one below), and
/// one quiet line for the other projects that moved, which opens into a
/// plain list of them. A week where nothing moved says so in a line.
/// `footer` follows inside the scroll (the iPhone puts the "Worth a look"
/// rows there). A pure leaf: hosts pass the week, the loaded pictures and
/// their pixel sizes by blob id, and the opener.
public struct TimelineWeekView<Footer: View>: View {
    let week: TimelineWeek
    let now: Date
    let images: [String: Image]
    let sizes: [String: CGSize]
    let onOpenProject: (String) -> Void
    let footer: Footer

    @State private var showsAlso = false

    public init(week: TimelineWeek, now: Date, images: [String: Image], sizes: [String: CGSize] = [:],
                onOpenProject: @escaping (String) -> Void, @ViewBuilder footer: () -> Footer) {
        self.week = week; self.now = now; self.images = images; self.sizes = sizes
        self.onOpenProject = onOpenProject; self.footer = footer()
    }

    /// Two cards to a row on a wide page, one on a narrow one.
    static func columnCount(pageWidth: CGFloat) -> Int {
        pageWidth >= TimelinePage.wideWidth ? 2 : 1
    }

    public var body: some View {
        // GeometryReader outside the scroll: the width is there on the first
        // layout, so a wide window never draws one column first.
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: TimelinePage.sectionSpacing) {
                    header
                    if TimelineFormat.movedNothing(week) {
                        Text(TimelineFormat.nothingMoved).font(TimelinePage.ledeFont).foregroundStyle(.secondary)
                            .accessibilityIdentifier("timeline.week.empty")
                    }
                    cards(columns: Self.columnCount(pageWidth: geo.size.width))
                    also
                    footer
                }
                .padding(TimelinePage.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id(week.week)
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

    @ViewBuilder private func cards(columns: Int) -> some View {
        let stories = TimelineFormat.cards(week)
        if !stories.isEmpty {
            let rows = stride(from: 0, to: stories.count, by: columns).map {
                Array(stories[$0..<min($0 + columns, stories.count)])
            }
            VStack(alignment: .leading, spacing: TimelinePage.cardSpacing) {
                ForEach(rows.indices, id: \.self) { index in
                    // Cards in a row share the tallest one's height.
                    HStack(alignment: .top, spacing: TimelinePage.cardSpacing) {
                        // By position: an older journal may send two stories for one project.
                        ForEach(Array(rows[index].enumerated()), id: \.offset) { _, story in card(story) }
                        if rows[index].count < columns { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func card(_ story: TimelineStory) -> some View {
        TimelineStoryCard(story: story, image: story.media.flatMap { images[$0.blobID] },
                          pixelSize: story.media.flatMap { sizes[$0.blobID] })
            .onTapGesture { onOpenProject(story.project.id) }
            .accessibilityAction(named: Text("Open project")) { onOpenProject(story.project.id) }
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
    init(week: TimelineWeek, now: Date, images: [String: Image], sizes: [String: CGSize] = [:],
         onOpenProject: @escaping (String) -> Void) {
        self.init(week: week, now: now, images: images, sizes: sizes, onOpenProject: onOpenProject) { EmptyView() }
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
