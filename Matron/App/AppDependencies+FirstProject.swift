import Foundation
import MatronJournal
import MatronModels
import MatronViewModels

@MainActor
extension AppDependencies {
    func makeFirstProjectViewModel(for session: UserSession) -> FirstProjectViewModel {
        let core = core(for: session)
        let key = FirstProjectProgress.defaultsKey(server: session.homeserverURL, userID: session.userID)
        let saved = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(FirstProjectProgress.self, from: $0) } ?? .init()
        let model = FirstProjectViewModel(
            api: agentRPCService(for: session), progress: saved,
            save: { progress in
                if let data = try? JSONEncoder().encode(progress) { UserDefaults.standard.set(data, forKey: key) }
            },
            send: { [weak self] id, prompt, localID in
                guard let self, self.isCurrent(stack: ObjectIdentifier(core), session: session) else { throw CancellationError() }
                await core.engine.ensurePlaceholderConversation(id: id, title: "My first project")
                guard self.isCurrent(stack: ObjectIdentifier(core), session: session) else { throw CancellationError() }
                try await core.engine.sendMessage(convoID: id, body: prompt, localID: localID)
            },
            readResult: { id in
                var query = ItemsListQuery()
                query.convoID = id; query.kind = .notice
                query.sort = .updated
                let notices = try await core.api.listItems(query)
                guard let notice = notices.items.first(where: {
                    $0.kind == .notice && $0.originConvoID == id
                    && ($0.title == FirstProjectResult.noticeTitle || $0.labels.contains("first-project-result"))
                    && $0.createdBy == .agent && (!$0.links.isEmpty || !$0.attachments.isEmpty)
                }) else { return nil }
                let missions = try? await core.api.conversationMissions(convoID: id)
                let projectID = missions?.first(where: { $0.isCurrent })?.mission.projectID
                    ?? missions?.first?.mission.projectID
                return FirstProjectResult(noticeID: notice.id, title: notice.title, projectID: projectID)
            })
        model.approvalSigner = approvalSigner(for: session)
        return model
    }

    func shouldOfferFirstProject(for session: UserSession) async -> Bool {
        let key = FirstProjectProgress.defaultsKey(server: session.homeserverURL, userID: session.userID)
        if let data = UserDefaults.standard.data(forKey: key),
           let progress = try? JSONDecoder().decode(FirstProjectProgress.self, from: data) {
            return !progress.dismissed && !progress.completed
        }
        // Ask the server: an empty local mirror immediately after sign-in
        // does not mean an existing account is a newcomer.
        guard let snapshot = try? await core(for: session).api.snapshot() else { return false }
        return snapshot.conversations.isEmpty
    }
}
