import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// What a project page opens, wired by the shell.
struct MacProjectPageActions {
    var onOpenMission: (String) -> Void = { _ in }
    var onOpenItem: (String) -> Void = { _ in }
    var onOpenMilestone: (Milestone) -> Void = { _ in }
    /// A conversation at one event (a chat file's `seq`).
    var onOpenConversationAt: (String, Int64) -> Void = { _, _ in }
}

/// What a project page needs of its view model — `ProjectDetailViewModel`,
/// or a test's fake (`MacProjectPageSlotTests`).
@MainActor protocol MacProjectPageModel: AnyObject {
    var projectID: String { get }
    func start()
    func stop()
}

extension ProjectDetailViewModel: MacProjectPageModel {}

/// The project page's view model, held by the shell rather than the page
/// (PR4 review M1): the page unmounts whenever a mission page replaces it,
/// and a view model rebuilt on Back starts with no detail-pass clock, so
/// `ProjectDetailViewModel`'s 60 s throttle never applied. Kept while it
/// shows the page's project for the same session's dashboard view model
/// (`owner`); any other project or owner builds a fresh one.
@MainActor struct MacProjectPageSlot<Model: MacProjectPageModel> {
    private(set) var model: Model?
    /// The page that last showed `model`: a page leaving after another
    /// has shown it (the two `onDisappear` / `.task` can run in either
    /// order) must not stop it. nil from callers that pass no page.
    private(set) var shownBy: AnyHashable?
    /// The project the page asked for when `model` was built, or when it
    /// last accepted `model` as its own (PR4 review M2). A redirect is the
    /// page's only when this is the page's project — recorded, not inferred
    /// from which ids `onChange` happened to observe.
    private(set) var builtFor: String?
    private(set) var owner: ObjectIdentifier?
    private(set) var isRunning = false

    init() {}

    /// `model` when it is `projectID`'s, for `owner`'s session: Back/Forward
    /// between two project pages changes `projectID` before `.task` swaps
    /// in the new view model, and without this the old project's content
    /// and actions would render — and act — under the new id for a frame.
    func current(projectID: String, owner: ObjectIdentifier) -> Model? {
        guard let model, model.projectID == projectID, self.owner == owner else { return nil }
        return model
    }

    /// The page's `.task(id: projectID)`: reuse the view model showing
    /// `projectID` (a redirected one too), else build one; then start it
    /// unless it is already running — a reused one was stopped when the
    /// page last left the screen.
    mutating func show(projectID: String, owner: ObjectIdentifier, page: AnyHashable? = nil, build: () -> Model) {
        let model: Model
        if let reused = current(projectID: projectID, owner: owner) {
            model = reused
        } else {
            self.model?.stop()
            model = build()
            self.model = model
            self.owner = owner
            isRunning = false
        }
        builtFor = projectID
        shownBy = page
        if !isRunning {
            model.start()
            isRunning = true
        }
    }

    /// The page left the screen. Only `owner`'s page may stop the model: on
    /// an account switch the new session's page can appear before the old
    /// one's `onDisappear` runs. Likewise only the `page` that last showed
    /// it, when pages say which they are.
    mutating func pageDidDisappear(owner: ObjectIdentifier, page: AnyHashable? = nil) {
        guard self.owner == owner else { return }
        if let page, page != shownBy { return }
        model?.stop()
        isRunning = false
    }

    /// The project to redirect the page to when the view model's id moved
    /// to `newID`, or nil: a view model built for another project (stale,
    /// its redirect landing after the user moved on) never moves the page.
    func redirect(to newID: String?, pageProjectID: String) -> String? {
        guard let newID, newID != pageProjectID, builtFor == pageProjectID else { return nil }
        return newID
    }

    /// A new session: the old session's view model must not survive it.
    mutating func reset() {
        model?.stop()
        self = Self()
    }
}

/// What a project page's files open: the page's own (`MacTimelineProjectHost`).
@MainActor enum MacProjectFiles {
    /// A roll-up file: a chat file opens its conversation at the event. An
    /// item file names its item by number: resolve it the way a tapped
    /// `matron://item/<n>` link is (one refresh on a miss), then open it, or
    /// say why not in the page's alert.
    static func openFile(_ file: ProjectFile, deps: AppDependencies?, session: UserSession,
                         actions: MacProjectPageActions, vm: ProjectDetailViewModel?) {
        switch file.source {
        case .chat(let convoID, let seq): actions.onOpenConversationAt(convoID, seq)
        case .item(let num):
            guard let deps else { return }
            Task {
                switch await deps.trackerItemLinkOutcome(num: num, session: session) {
                case .open(let itemID): actions.onOpenItem(itemID)
                case .explain(let message): vm?.error = message
                case .ignore: break
                }
            }
        }
    }
}

/// "All · box-a 2 · box-b 1 · box-c 1": the sessions' boxes. A click on a box
/// shows only its sessions; clicking it again, or All, shows them all.
/// Until the sessions themselves have loaded the counts are the journal's
/// and there is nothing to filter, so they are plain text.
struct MacProjectBoxFilter: View {
    let counts: [ProjectBoxCount]
    let selected: String?
    let enabled: Bool
    let onSelect: (String?) -> Void

    var body: some View {
        if enabled {
            PillFlowLayout(spacing: 12) {
                chip("All", isOn: selected == nil) { onSelect(nil) }
                ForEach(counts, id: \.box) { count in
                    chip("\(count.box) \(count.count)", isOn: selected == count.box) {
                        onSelect(ProjectPageSections.toggled(selected, box: count.box))
                    }
                }
            }
        } else {
            Text(ProjectsFormat.boxCounts(counts)).font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: isOn ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
