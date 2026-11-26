import SwiftUI
import MatronModels
import MatronViewModels

/// One model for this presentation; reopening reads the account's saved
/// progress. Ordinary shell refreshes cannot reset an in-flight request.
struct FirstProjectSheet: View {
    @State private var model: FirstProjectViewModel
    let nav: AppShellNavigation

    init(deps: AppDependencies, session: UserSession, nav: AppShellNavigation) {
        _model = State(initialValue: deps.makeFirstProjectViewModel(for: session))
        self.nav = nav
    }

    var body: some View {
        FirstProjectView(model: model,
            openConversation: { nav.openChat($0) },
            openResult: { nav.openItem($0) },
            openProject: { nav.openPageLink(.project(id: $0)) },
            showConversations: { nav.tab = .conversations })
    }
}
