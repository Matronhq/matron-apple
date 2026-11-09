import SwiftUI
import MatronModels

/// One week of the Projects timeline: the title and dates, the week's
/// lede, its story cards (two columns from 700 pt, one below), and one
/// quiet line for the projects that moved without a story, which opens
/// into a plain list of them. `footer` follows inside the scroll (the
/// iPhone puts the "Worth a look" rows there). A pure leaf: hosts pass the
/// week, the loaded pictures by blob id and the two openers.
public struct TimelineWeekView<Footer: View>: View {
    let week: TimelineWeek
    /// The week's sidebar sentence: the lede when the week has none written.
    let sentence: String?
    let now: Date
    let images: [String: Image]
    let onOpenProject: (String) -> Void
    let onOpenItem: (String) -> Void
    let footer: Footer

    @State private var showsAlso = false

    public init(week: TimelineWeek, sentence: String? = nil, now: Date, images: [String: Image],
                onOpenProject: @escaping (String) -> Void, onOpenItem: @escaping (String) -> Void,
                @ViewBuilder footer: () -> Footer) {
        self.week = week; self.sentence = sentence; self.now = now; self.images = images
        self.onOpenProject = onOpenProject; self.onOpenItem = onOpenItem; self.footer = footer()
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(TimelineFormat.pageTitle(week, now: now)).font(TimelinePage.titleFont)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                if let dates = TimelineFormat.pageDates(week, now: now) {
                    Text(dates).font(TimelinePage.datesFont).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let lede = TimelineFormat.lede(week, sentence: sentence) {
                Text(MissionsDashboardFormat.statusPreviewText(lede))
                    .font(TimelinePage.ledeFont).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func cards(columns: Int) -> some View {
        if !week.stories.isEmpty {
            let rows = stride(from: 0, to: week.stories.count, by: columns).map {
                Array(week.stories[$0..<min($0 + columns, week.stories.count)])
            }
            VStack(alignment: .leading, spacing: TimelinePage.cardSpacing) {
                ForEach(rows.indices, id: \.self) { index in
                    // Cards in a row share the tallest one's height.
                    HStack(alignment: .top, spacing: TimelinePage.cardSpacing) {
                        ForEach(rows[index], id: \.project.id) { story in card(story) }
                        if rows[index].count < columns { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func card(_ story: TimelineStory) -> some View {
        TimelineStoryCard(story: story, image: story.media.flatMap { images[$0.blobID] }, onOpenItem: onOpenItem)
            .onTapGesture { onOpenProject(story.project.id) }
            .accessibilityAction(named: Text("Open project")) { onOpenProject(story.project.id) }
    }

    @ViewBuilder private var also: some View {
        if !week.also.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button { showsAlso.toggle() } label: {
                    Text(TimelineFormat.alsoLine(week.also.count) + TimelineFormat.opensMark).font(TimelinePage.lineFont)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(TimelineFormat.alsoLine(week.also.count))
                .accessibilityIdentifier("timeline.week.also")
                if showsAlso {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(week.also, id: \.id) { project in
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
    init(week: TimelineWeek, sentence: String? = nil, now: Date, images: [String: Image],
         onOpenProject: @escaping (String) -> Void, onOpenItem: @escaping (String) -> Void) {
        self.init(week: week, sentence: sentence, now: now, images: images, onOpenProject: onOpenProject,
                  onOpenItem: onOpenItem) { EmptyView() }
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
