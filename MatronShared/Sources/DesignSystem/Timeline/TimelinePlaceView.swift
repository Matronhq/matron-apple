import SwiftUI
import MatronModels

/// One place of the timeline as `content` says it stands: a week, one of
/// the three lists, progress, the retry, or the empty state. `footer`
/// follows the week's cards and the empty state (the iPhone's "Worth a
/// look" rows). A pure leaf: hosts pass the content, the loaded pictures
/// and the actions, and own the reads, the image loading and the alert.
public struct TimelinePlaceView<Footer: View>: View {
    let content: TimelinePlaceContent
    let now: Date
    let images: [String: Image]
    let asked: Set<String>
    let onOpenProject: (String) -> Void
    let onOpenItem: (String) -> Void
    let onAsk: (StalledProject) -> Void
    let onLoadMoreFinished: () -> Void
    let onRetry: () -> Void
    let footer: Footer

    public init(content: TimelinePlaceContent, now: Date, images: [String: Image], asked: Set<String>,
                onOpenProject: @escaping (String) -> Void, onOpenItem: @escaping (String) -> Void,
                onAsk: @escaping (StalledProject) -> Void, onLoadMoreFinished: @escaping () -> Void,
                onRetry: @escaping () -> Void, @ViewBuilder footer: () -> Footer) {
        self.content = content; self.now = now; self.images = images; self.asked = asked
        self.onOpenProject = onOpenProject; self.onOpenItem = onOpenItem; self.onAsk = onAsk
        self.onLoadMoreFinished = onLoadMoreFinished; self.onRetry = onRetry; self.footer = footer()
    }

    public var body: some View {
        switch content {
        case .week(let week, let sentence):
            TimelineWeekView(week: week, sentence: sentence, now: now, images: images,
                             onOpenProject: onOpenProject, onOpenItem: onOpenItem) { footer }
        case .quiet(let list):
            StalledListView(title: TimelineFormat.wentQuiet, lede: TimelineFormat.quietLede, list: list, now: now,
                            onOpenProject: onOpenProject, onAsk: onAsk, asked: asked)
        case .long(let list):
            StalledListView(title: TimelineFormat.openLong, lede: TimelineFormat.longLede, list: list, now: now,
                            onOpenProject: onOpenProject, onAsk: onAsk, asked: asked)
        case .finished(let rows, let hasMore):
            FinishedListView(rows: rows, now: now, onOpenProject: onOpenProject,
                             onLoadMore: hasMore ? onLoadMoreFinished : nil)
        case .nothingYet:
            // Centred in the page, scrolling (and refreshable) like the week.
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ContentUnavailableView("Nothing has moved yet", systemImage: ProjectGlyph.symbol)
                        footer
                    }
                    .padding(TimelinePage.padding)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
        case .failed:
            ContentUnavailableView {
                Label("Couldn't load this", systemImage: ProjectGlyph.symbol)
            } description: {
                Text("The journal didn't answer. Check the connection and try again.")
            } actions: {
                Button("Try again", action: onRetry)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

public extension TimelinePlaceView where Footer == EmptyView {
    init(content: TimelinePlaceContent, now: Date, images: [String: Image], asked: Set<String>,
         onOpenProject: @escaping (String) -> Void, onOpenItem: @escaping (String) -> Void,
         onAsk: @escaping (StalledProject) -> Void, onLoadMoreFinished: @escaping () -> Void,
         onRetry: @escaping () -> Void) {
        self.init(content: content, now: now, images: images, asked: asked, onOpenProject: onOpenProject,
                  onOpenItem: onOpenItem, onAsk: onAsk, onLoadMoreFinished: onLoadMoreFinished,
                  onRetry: onRetry) { EmptyView() }
    }
}
