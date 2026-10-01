import SwiftUI
import MatronModels

/// One project on the home screen (Projects view v2, cards mockup): the
/// title and needs-you, what it is about (the status, else the goal), ONE
/// box — what it waits on from you, else its latest milestone — and a
/// footer of missions and live sessions. Nothing from two levels down.
public struct ProjectCardView: View {
    let card: ProjectCard
    let now: Date
    let onOpen: () -> Void
    public init(card: ProjectCard, now: Date, onOpen: @escaping () -> Void) {
        self.card = card; self.now = now; self.onOpen = onOpen
    }

    // The Mac's text styles run ~3 pt smaller than iOS's; the card is
    // sized for reading at a glance on both, so the Mac names its sizes.
    #if os(macOS)
    private static let titleFont = Font.system(size: 20, weight: .semibold)
    private static let bodyFont = Font.system(size: 15)
    private static let boxFont = Font.system(size: 14)
    private static let noteFont = Font.system(size: 12)
    #else
    private static let titleFont = Font.title3.weight(.semibold)
    private static let bodyFont = Font.body
    private static let boxFont = Font.subheadline
    private static let noteFont = Font.caption
    #endif

    public var body: some View {
        Button(action: onOpen) { content }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .accessibilityIdentifier("projects.card.\(card.project.num)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            description
            box
            Spacer(minLength: 0)
            Text(ProjectFeedFormat.cardFooter(openMissions: card.project.missions.open, sessionsNow: card.sessionsNow))
                .font(Self.noteFont).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(DashboardCardChrome())
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(card.project.title).font(Self.titleFont).lineLimit(2)
            Spacer(minLength: 8)
            NeedsYouPill(count: card.needsYouCount)
        }
    }

    @ViewBuilder private var description: some View {
        if let text = ProjectFeedFormat.cardDescription(card.project) {
            Text(MissionsDashboardFormat.statusText(text)).font(Self.bodyFont).lineLimit(4).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(ProjectsFormat.noStatusLine(latest: card.latestMilestone, now: now))
                .font(Self.bodyFont).foregroundStyle(.secondary).lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Waiting on you (red) beats the latest milestone (grey); neither, no box.
    @ViewBuilder private var box: some View {
        if let waiting = card.waitingOn {
            boxRow(fill: Color.red.opacity(0.08)) {
                Image(systemName: "hourglass").foregroundStyle(Color.red)
                Text(ProjectFeedFormat.waitingText(waiting)).foregroundStyle(Color.red).lineLimit(2)
            } trailing: {
                Text(ProjectFeedFormat.waitingTrailing(waiting)).foregroundStyle(Color.red.opacity(0.8))
            }
            .accessibilityElement(children: .combine)
        } else if let latest = card.latest {
            boxRow(fill: Color.primary.opacity(0.05)) {
                Circle().fill(Color.green).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(ProjectsFormat.oneLine(latest.title)).lineLimit(2)
            } trailing: {
                Text(MissionsDashboardFormat.relative(latest.at, now: now)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func boxRow<Lead: View, Trail: View>(fill: Color, @ViewBuilder _ lead: () -> Lead,
                                                 @ViewBuilder trailing: () -> Trail) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            lead()
                .font(Self.boxFont)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing().font(Self.noteFont.monospacedDigit()).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
