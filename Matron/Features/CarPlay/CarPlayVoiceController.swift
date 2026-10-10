import CarPlay
import UIKit
import MatronJournal
import MatronModels
import MatronVoice

// Voice mode needs `VoiceCapture`, which only an Xcode with the iOS 26 SDK
// compiles (see `VoiceCapture.swift`).
#if compiler(>=6.2)

/// Voice mode on the car's display: a thin adapter between the voice
/// engine and CarPlay's templates. It maps engine state to a voice-control
/// template and that template's buttons to engine events; no voice logic
/// lives here.
///
/// What the car's rules for a voice-based conversation app ask, and where
/// each is met:
///
/// - voice first on launch: the root is the voice-control template, and a
///   sitting starts listening as soon as the scene is active;
/// - no reply text on the display: `CarPlayVoiceScreen` draws only the
///   state, the conversation's name and buttons;
/// - the audio session held only while voice is in use: the engine lets
///   go of it whenever it is neither listening nor speaking;
/// - the microphone only while the voice-control template shows: opening
///   the conversation list, or leaving the app, pauses the sitting;
/// - two templates deep: voice control, and the conversation list.
@available(iOS 26.4, *)
@MainActor
final class CarPlayVoiceController: NSObject, CPInterfaceControllerDelegate {
    private let deps: AppDependencies
    private let link: CarPlayLink
    private let settings = VoiceSettings()

    private var interface: CPInterfaceController?
    private var template: CPVoiceControlTemplate?
    private var shown: CarPlayVoiceScreen.Model?
    private var chats: CPListTemplate?

    private var voice: VoiceModeSession?
    private var session: UserSession?
    private var idle = CarPlayVoiceScreen.Idle.ready
    /// A sitting is being set up (the session restored, the sync started).
    private var starting = false
    /// What to open once the sitting that is ending has let go of the
    /// audio: two sittings never hold it at once.
    private var next: VoiceModeEntry?
    private var isActive = false
    /// Coming to the front opens the microphone only on arrival: at
    /// launch, and after the scene was really in the background. A system
    /// alert passing over the display does not.
    private var listensOnActive = true
    /// Keeps the databases open while the car's scene is in front: the
    /// iPhone's own window is usually in the background then, which would
    /// otherwise suspend them.
    private var databases: DatabaseSuspensionController.Activity?

    init(deps: AppDependencies, link: CarPlayLink) {
        self.deps = deps
        self.link = link
    }

    // MARK: The scene

    func connect(_ interface: CPInterfaceController) {
        self.interface = interface
        interface.delegate = self
        link.onSignedOut = { [weak self] in self?.signedOut() }
        link.onSignedIn = { [weak self] in self?.signedIn() }
        render()
    }

    func disconnect() {
        next = nil
        voice?.end()
        isActive = false
        releaseDatabases()
        link.onSignedOut = nil
        link.onSignedIn = nil
        interface = nil
        template = nil
        shown = nil
        chats = nil
    }

    /// The car's scene is in front: at launch, and every time the user
    /// comes back to Matron on the car's display. Either way voice mode is
    /// listening when they arrive.
    func becameActive() {
        isActive = true
        if databases == nil { databases = DatabaseSuspensionController.shared.beginActivity(named: "carplay-voice") }
        guard listensOnActive else { return }
        listensOnActive = false
        guard chats == nil else { return }
        guard let voice else {
            if !starting {
                let entry = next ?? .queue
                next = nil
                begin(entry)
            }
            return
        }
        voice.runner.send(.appForegrounded)
        if voice.runner.state.phase == .waiting { voice.runner.send(.tap) }
    }

    func enteredBackground() {
        isActive = false
        listensOnActive = true
        voice?.runner.send(.appBackgrounded)
        if let session {
            // A note still on its way out gets the same grace as on the
            // iPhone before the databases are let go of.
            OutboxBackgroundGrace.holdIfNeeded(engine: deps.syncService(for: session) as? JournalSyncEngine)
        }
        releaseDatabases()
        // The iPhone's window reports the background only when it was in
        // front itself. With the car's scene the last one to leave, nothing
        // else tells the databases to let go before the process is
        // suspended.
        if UIApplication.shared.applicationState == .background {
            DatabaseSuspensionController.shared.setInBackground(true)
        }
    }

    private func releaseDatabases() {
        databases?.end()
        databases = nil
    }

    // MARK: Sittings

    private func begin(_ entry: VoiceModeEntry) {
        if let voice {
            next = entry
            voice.end()
            return
        }
        if starting {
            // Asked for while another is being set up: it opens next.
            next = entry
            return
        }
        starting = true
        Task { [weak self] in
            await self?.open(entry)
            guard let self else { return }
            self.starting = false
            if let next = self.next, self.interface != nil, self.isActive, self.chats == nil {
                self.next = nil
                self.begin(next)
            }
        }
    }

    private func open(_ entry: VoiceModeEntry) async {
        guard let session = await resolveSession() else { return show(.signedOut) }
        guard VoiceModeAvailability.isSupported else { return show(.unavailable) }
        // With the phone locked the car is the only scene there is, and
        // nothing else has started the sync.
        try? await deps.syncService(for: session).start()
        // Everything below is checked after the last wait: the user may
        // have signed out, left, or started recording on the iPhone since.
        // The same sign-in, whatever has happened to its tokens since.
        guard let now = self.session, now.userID == session.userID, now.deviceID == session.deviceID else {
            return show(self.session == nil ? .signedOut : .ready)
        }
        guard interface != nil, isActive, voice == nil else { return }
        guard !link.phoneHoldsMicrophone() else { return show(.microphoneBusy) }
        guard chats == nil else {
            // The list is showing: the sitting opens when it goes.
            if next == nil { next = entry }
            return
        }
        let made = VoiceModeSession(entry: entry, session: session, deps: deps, settings: settings,
                                    keepsScreenAwake: false)
        // The iPhone gets the microphone back even if the car has gone and
        // taken this controller with it.
        made.runner.onEnded = { [weak self, link] _ in
            link.setCarActive(false)
            self?.ended()
        }
        voice = made
        link.setCarActive(true)
        made.start(entry)
        observe(made)
        render()
    }

    private func resolveSession() async -> UserSession? {
        if let session { return session }
        deps.installLifecycleHooks()
        session = link.session
        if session == nil {
            // A sign-out still clearing up owns the databases until it is done.
            await deps.awaitPendingTeardown()
            session = link.session
            if session == nil { session = try? await deps.auth.restoreSession() }
        }
        return session
    }

    private func ended() {
        voice = nil
        link.setCarActive(false)
        idle = session == nil ? .signedOut : .ready
        if let next, interface != nil, isActive, chats == nil {
            self.next = nil
            begin(next)
        }
        render()
    }

    /// The user signed in on the iPhone while the car said to.
    private func signedIn() {
        session = link.session
        guard voice == nil, idle == .signedOut || starting else { return }
        // A sitting still being set up for the account that left gives up
        // by itself, and shows Ready when it does.
        if !starting { show(.ready) }
    }

    private func signedOut() {
        session = nil
        next = nil
        idle = .signedOut
        if let voice { voice.end() } else { render() }
        if chats != nil { interface?.popToRootTemplate(animated: false) { _, _ in } }
    }

    private func show(_ idle: CarPlayVoiceScreen.Idle) {
        self.idle = idle
        render()
    }

    private func observe(_ sitting: VoiceModeSession) {
        withObservationTracking {
            _ = sitting.runner.state
        } onChange: { [weak self, weak sitting] in
            Task { @MainActor in
                guard let self, let sitting, self.voice === sitting else { return }
                self.render()
                self.observe(sitting)
            }
        }
    }

    // MARK: Voice control

    private func render() {
        guard let interface else { return }
        let model = voice.map { CarPlayVoiceScreen.model($0.runner.state) } ?? CarPlayVoiceScreen.model(idle)
        guard model != shown else { return }
        // The list is over the voice screen: it is redrawn when the list goes.
        guard chats == nil else { return }
        if let template, model.layout == shown?.layout {
            template.activateVoiceControlState(withIdentifier: model.active.rawValue)
            settle(template, on: model.active)
        } else {
            // A state's titles and buttons are fixed once shown, so a new
            // layout is a new template, opening on the active state.
            let made = makeTemplate(model)
            template = made
            interface.setRootTemplate(made, animated: false) { [weak self] done, _ in
                Task { @MainActor in
                    // Not shown: forget it, so the next change draws afresh.
                    guard let self, !done, self.template === made else { return }
                    self.template = nil
                    self.shown = nil
                }
            }
        }
        shown = model
    }

    /// The car ignores a change of state that comes too soon after the
    /// last one. Looks again shortly, and repeats it if it did not take.
    private func settle(_ template: CPVoiceControlTemplate, on state: CarPlayVoiceScreen.StateID) {
        Task { [weak self, weak template] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, let template, self.template === template, self.shown?.active == state,
                  template.activeStateIdentifier != state.rawValue else { return }
            template.activateVoiceControlState(withIdentifier: state.rawValue)
        }
    }

    private func makeTemplate(_ model: CarPlayVoiceScreen.Model) -> CPVoiceControlTemplate {
        // The template opens on its first state.
        let order = [model.active] + CarPlayVoiceScreen.StateID.allCases.filter { $0 != model.active }
        let limit = min(CarPlayVoiceScreen.buttonLimit, CPVoiceControlState.maximumActionButtonCount)
        let states = order.map { id -> CPVoiceControlState in
            let state = CPVoiceControlState(identifier: id.rawValue, titleVariants: model.layout.titles[id],
                                            image: CarPlaySymbols.image(for: id), repeats: true)
            state.actionButtons = (model.layout.buttons[id] ?? []).prefix(limit).map { button in
                let made = CPButton(image: CarPlaySymbols.image(for: button)) { [weak self] _ in self?.pressed(button) }
                made.title = button.title
                return made
            }
            return state
        }
        let template = CPVoiceControlTemplate(voiceControlStates: states)
        template.trailingNavigationBarButtons = [CPBarButton(title: "Chats") { [weak self] _ in self?.showChats() }]
        return template
    }

    private func pressed(_ button: CarPlayVoiceScreen.Button) {
        guard let voice else {
            // No sitting: Talk starts one.
            if button == .talk, !starting { begin(.queue) }
            return
        }
        voice.runner.send(button.event)
    }

    // MARK: Conversations

    private func showChats() {
        guard let interface, chats == nil, let session else { return }
        let store = deps.journalStore(for: session)
        let names = (try? store.agentNames()) ?? [:]
        let conversations = ((try? store.conversations()) ?? []).map { record in
            QueueConversation(id: record.id, title: record.title, boxName: record.agentDeviceID.flatMap { names[$0] },
                              unreadCount: record.unreadCount, sessionState: record.sessionState)
        }
        let items = CarPlayChats.rows(conversations).map { row -> CPListItem in
            let item = CPListItem(text: row.title, detailText: row.detail)
            item.handler = { [weak self] _, done in
                self?.chose(row)
                done()
            }
            return item
        }
        let list = CPListTemplate(title: "Chats", sections: [CPListSection(items: items)])
        list.emptyViewTitleVariants = ["No conversations"]
        chats = list
        // The microphone is open only while the voice screen shows.
        voice?.runner.send(.appBackgrounded)
        interface.pushTemplate(list, animated: true) { [weak self] done, _ in
            Task { @MainActor in
                // The list never showed: the voice screen is still in front.
                guard let self, !done, self.chats === list else { return }
                self.chatsClosed()
            }
        }
    }

    private func chose(_ row: CarPlayChatRow) {
        next = .conversation(id: row.id, title: row.title, boxName: row.boxName)
        interface?.popToRootTemplate(animated: true) { _, _ in }
    }

    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        // Leaving the app hides the list too, but leaves it on the stack.
        guard aTemplate === chats, interface?.templates.contains(where: { $0 === aTemplate }) != true else { return }
        chatsClosed()
    }

    private func chatsClosed() {
        chats = nil
        if let next, !starting {
            // A conversation was chosen: voice mode opens on it, listening.
            self.next = nil
            begin(next)
        } else if isActive {
            voice?.runner.send(.appForegrounded)
        }
        render()
    }
}

/// The picture beside each state's title.
@available(iOS 26.4, *)
enum CarPlaySymbols {
    static func image(for state: CarPlayVoiceScreen.StateID) -> UIImage? {
        switch state {
        case .listening: return levels("waveform")
        case .speaking: return levels("speaker.wave.3.fill")
        case .sending: return still("arrow.up.circle.fill")
        case .working: return levels("ellipsis")
        case .ready: return still("mic.fill")
        }
    }

    /// An answer's own button carries its label as the title; the tick
    /// only marks it as something to press.
    static func image(for button: CarPlayVoiceScreen.Button) -> UIImage {
        let name: String
        switch button {
        case .label: name = "checkmark.circle"
        case .skip: name = "forward.end.fill"
        case .stop: name = "stop.fill"
        case .talk: name = "mic.fill"
        case .cancel: name = "xmark"
        }
        return UIImage(systemName: name) ?? UIImage()
    }

    private static let configuration = UIImage.SymbolConfiguration(pointSize: 96, weight: .medium)

    private static func still(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: configuration)
    }

    /// The symbol filling up and emptying again, as one animated image.
    private static func levels(_ name: String) -> UIImage? {
        let steps: [Double] = [0.1, 0.4, 0.7, 1, 0.7, 0.4]
        let frames = steps.compactMap { UIImage(systemName: name, variableValue: $0, configuration: configuration) }
        guard frames.count == steps.count else { return still(name) }
        return UIImage.animatedImage(with: frames, duration: 1.2)
    }
}

/// The car's scene, named in Info.plist's scene manifest. iOS makes one
/// when the app is opened on a car's display, and only on a build that
/// carries the CarPlay entitlement.
@available(iOS 26.4, *)
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayVoiceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        let made = CarPlayVoiceController(deps: AppRoot.dependencies, link: .shared)
        controller = made
        made.connect(interfaceController)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        controller?.disconnect()
        controller = nil
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        controller?.becameActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        controller?.enteredBackground()
    }
}

#endif
