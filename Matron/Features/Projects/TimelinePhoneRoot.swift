import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The iPhone's Projects root with the timeline shown: the week picked in
/// the title's menu, then "Worth a look", three rows that push their
/// lists. A story pushes the project's story. Its alert is
/// `ProjectsTabRoot`'s one.
struct TimelinePhoneRoot: View {
    let state: TimelineHostState
    let viewModel: TimelineViewModel
    let session: UserSession
    let onOpenStory: (String) -> Void
    let onOpenList: (TimelinePlace) -> Void
    let onOpenItem: (String) -> Void

    /// One entry of the week menu.
    struct WeekChoice: Identifiable, Equatable {
        let week: String
        let title: String
        var id: String { week }
    }

    /// The weeks newest first: "This week", "Last week", then their dates.
    static func weekChoices(_ weeks: [TimelineWeekSummary]) -> [WeekChoice] {
        weeks.enumerated().map { WeekChoice(week: $1.week, title: TimelineFormat.sidebarTitle(index: $0, week: $1.week)) }
    }

    /// The week page's place: the week the menu shows.
    static func place(_ state: TimelineHostState) -> TimelinePlace? {
        state.week.map { .week($0) }
    }

    var body: some View {
        TimelinePlacePage(host: state, viewModel: viewModel, place: Self.place(state), session: session,
                          onOpenProject: onOpenStory, onOpenItem: onOpenItem) {
            worthALook
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu { weekMenu }
        // Back from a list: the view model reads the week again.
        .onAppear {
            if let week = state.week, state.place != .week(week) { state.select(.week(week)) }
        }
    }

    private var title: String {
        let choices = Self.weekChoices(viewModel.weeks)
        return choices.first { $0.week == state.week }?.title ?? "Projects"
    }

    @ViewBuilder private var weekMenu: some View {
        ForEach(Self.weekChoices(viewModel.weeks)) { choice in
            Button { state.select(.week(choice.week)) } label: {
                if choice.week == state.week {
                    Label(choice.title, systemImage: "checkmark")
                } else {
                    Text(choice.title)
                }
            }
        }
        if viewModel.hasEarlierWeeks {
            Button("Earlier weeks") { Task { await viewModel.loadEarlierWeeks() } }
        }
    }

    /// "Worth a look": each row pushes its list, with its count when known.
    private var worthALook: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(TimelineFormat.worthALook)
                .font(.footnote.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            row(.quiet, symbol: "circle.lefthalf.filled", TimelineFormat.wentQuiet, count: viewModel.quiet?.total)
            Divider()
            row(.long, symbol: "hourglass", TimelineFormat.openLong, count: viewModel.long?.total)
            Divider()
            // The journal sends no finished total; a count of the rows
            // loaded so far would read as one.
            row(.finished, symbol: "checkmark", TimelineFormat.finished, count: nil)
        }
        .padding(.top, 8)
    }

    private func row(_ place: TimelinePlace, symbol: String, _ title: String, count: Int?) -> some View {
        Button { onOpenList(place) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(Color.primary)
                    .accessibilityHidden(true)
                Text(title).foregroundStyle(Color.primary)
                Spacer(minLength: 8)
                if let count { Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .font(.body)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("timeline.phone.\(place)")
    }
}
