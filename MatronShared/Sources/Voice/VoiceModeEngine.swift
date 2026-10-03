import Foundation

/// Voice mode's state machine (spec 2026-10-03 §3): a pure function from a
/// state and an event to the next state and the things to do. It never
/// touches audio, the network or a clock: capture, playback, uploads,
/// sends and timers are `Effect` values a runner carries out, and what
/// they produce comes back as `Event`s. One engine drives the iPhone
/// screen, the Mac's stage and CarPlay; it knows about none of them.
///
/// ```
/// idle ─► listening ─► sending ─► waiting ─► speaking ─► listening …
///                         │                      ▲
///                         └─► confirming ────────┘
/// ```
public enum VoiceModeEngine {
    // MARK: Values

    public struct Config: Equatable, Sendable {
        /// "Talk over the agent": the microphone stays open under a clip.
        public var talkOver = true
        /// Whether "Say more for the detail" follows a reply (the first few times).
        public var offerMore = true
        /// Silence after speech that ends an utterance.
        public var endOfSpeechSilence: TimeInterval = 1.5
        /// The same, when the words so far are a command and nothing else.
        public var commandSilence: TimeInterval = 0.6
        /// Nothing said at all: the microphone closes.
        public var noSpeechTimeout: TimeInterval = 8
        public var maxUtterance: TimeInterval = 120
        /// No transcript by now: the recording goes as a plain voice note.
        public var transcriptTimeout: TimeInterval = 8
        /// How long "Sending: Go" waits for "cancel".
        public var confirmWindow: TimeInterval = 3
        /// Speech must last this long under a clip before the clip ducks.
        public var talkOverOnset: TimeInterval = 0.3
        /// Words must follow within this long, or the clip carries on.
        public var talkOverWords: TimeInterval = 1
        /// This many false starts inside one clip switch talking-over off
        /// for the audio route.
        public var falseTriggerLimit = 3
        public var moreHintLimit = 3
        /// Voice mode ends itself after this long without an exchange (§11).
        public var idleEnd: TimeInterval = 30 * 60

        public init() {}
    }

    public enum Phase: String, Equatable, Sendable { case idle, listening, sending, confirming, waiting, speaking }

    public enum TimerID: String, Hashable, Sendable, CaseIterable {
        case noSpeech, silence, maxUtterance, transcript, confirm, talkOverOnset, talkOverWords, idle
    }

    /// `record` writes the utterance to a file; `monitor` only watches for
    /// speech and words under a clip, keeping a rolling half second.
    public enum CaptureMode: String, Equatable, Sendable { case record, monitor }
    public enum Earcon: String, Equatable, Sendable, CaseIterable { case micOpen, sent, error }
    public enum SpeechLevel: String, Equatable, Sendable { case short, more, section, system }
    public enum SendTarget: Equatable, Sendable { case conversation(String), item(String) }
    public enum EndReason: String, Equatable, Sendable { case user, idle }
    public enum Interruption: Equatable, Sendable { case began, ended(shouldResume: Bool) }

    public struct Utterance: Equatable, Sendable {
        public let id: Int
        public let text: String
        public let level: SpeechLevel
        public init(id: Int, text: String, level: SpeechLevel) { self.id = id; self.text = text; self.level = level }
    }

    public enum Effect: Equatable, Sendable {
        case activateAudio
        case releaseAudio
        case startCapture(CaptureMode)
        /// Monitor becomes record, keeping the half second already heard.
        case promoteCapture
        /// `keep`: the file becomes the current recording. Otherwise it is deleted.
        case stopCapture(keep: Bool)
        case play(Utterance)
        case stopPlayback
        case duck
        case restoreVolume
        case earcon(Earcon)
        /// Upload the current recording and answer with `.transcript` or `.uploadFailed`.
        case upload
        /// Send the current recording as a voice note (uploading it first
        /// if need be; kept and retried when offline).
        case sendVoiceNote(SendTarget)
        case sendItemAction(itemID: String, label: String)
        case sendPromptReply(convoID: String, seq: Int64, choice: String?, text: String?)
        case discardRecording
        case startTimer(TimerID, TimeInterval)
        case cancelTimer(TimerID)
        /// Tell the engine when this conversation's turns start and end
        /// and what they end with.
        case watch(convoID: String)
        case keepScreenAwake(Bool)
        case ended(EndReason)
    }

    public enum Start: Equatable, Sendable {
        /// From inside a conversation: voice mode talks to it.
        case conversation(id: String, title: String, boxName: String?)
        /// From anywhere else: what needs the user, then the conversation
        /// used last (spec §5).
        case queue(entries: [VoiceEntry], lastConvoID: String?, lastTitle: String, lastBoxName: String?)
    }

    public enum Event: Equatable, Sendable {
        case start(Start)
        case end
        /// A tap anywhere on the voice screen.
        case tap
        case sendTapped
        /// One of the current thing's label buttons.
        case actionTapped(String)
        case speechStarted
        case speechEnded
        /// The on-device recogniser's words for the utterance so far.
        case words(String)
        case captureFailed
        /// The journal's transcript, or `nil` when it has none to give.
        case transcript(String?)
        case uploadFailed
        /// A send could not leave: offline.
        case sendFailed
        case arrived(VoiceEntry)
        /// Answered elsewhere, closed, or (`expired`) timed out.
        case resolved(id: String, expired: Bool)
        case turnStarted(convoID: String)
        case turnEnded(convoID: String)
        case playbackFinished(Int)
        case timerFired(TimerID)
        case interruption(Interruption)
        case appBackgrounded
        case appForegrounded
        /// The audio route's identity ("Speaker", "AirPods Pro", a car).
        case routeChanged(String)
        case configChanged(Config)
    }

    public enum AfterPlayback: String, Equatable, Sendable { case listen, confirm, wait, next }

    public struct Confirm: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable { case sending, didYouMean }
        public let kind: Kind
        public let label: String
        public let send: Effect
    }

    public struct State: Equatable, Sendable {
        public var config = Config()
        public var phase: Phase = .idle
        /// Where plain speech goes when nothing else claims it.
        public var convoID: String?
        public var convoTitle = ""
        public var boxName: String?
        /// Still reading "what needs you".
        public var inQueue = false
        public var queue: [VoiceEntry] = []
        /// Things that arrived while the engine was busy, oldest first.
        public var inbox: [VoiceEntry] = []
        /// The thing last read out: what an answer is matched against.
        public var current: VoiceEntry?
        /// 1 short, 2 longer, 3 the message in sections.
        public var level = 0
        public var section = 0
        public var askedGoOn = false
        public var playing: Utterance?
        public var after: AfterPlayback = .listen
        /// The line being spoken, for a phone screen. Never for a car's.
        public var caption: String?
        public var capture: CaptureMode?
        public var audioActive = false
        public var heard = ""
        public var speechSeen = false
        public var speechActive = false
        public var ducked = false
        public var confirm: Confirm?
        public var timers: Set<TimerID> = []
        public var working: Set<String> = []
        public var watched: Set<String> = []
        public var route = ""
        public var talkOverOffRoutes: Set<String> = []
        public var falseTriggers = 0
        public var pendingNotice: String?
        public var moreHints = 0
        public var paused = false
        public var nextUtterance = 1
        /// Entry ids already read out, so nothing is said twice.
        public var said: Set<String> = []

        public init() {}

        /// The labels to offer as buttons right now.
        public var labels: [String] { current?.labels ?? [] }
        public var talkOverAllowed: Bool { config.talkOver && !talkOverOffRoutes.contains(route) }
        /// The conversation a screen should name.
        public var title: String { current?.convoTitle.isEmpty == false ? current!.convoTitle : convoTitle }
        public var isAgentWorking: Bool {
            guard let id = current?.convoID ?? convoID else { return false }
            return working.contains(id)
        }
    }

    public static func reduce(_ state: State, _ event: Event) -> (State, [Effect]) {
        var machine = Machine(s: state)
        machine.handle(event)
        return (machine.s, machine.fx)
    }

    /// Whether `heard` is the clip's own words coming back through the
    /// microphone: every word of it, in order, inside the clip's text.
    public static func isEcho(_ heard: String, of clip: String) -> Bool {
        let words = VoiceText.words(heard)
        let spoken = VoiceText.words(clip)
        guard !words.isEmpty, words.count <= spoken.count else { return false }
        return (0...(spoken.count - words.count)).contains { Array(spoken[$0..<($0 + words.count)]) == words }
    }
}

// MARK: - The machine

private struct Machine {
    typealias Engine = VoiceModeEngine
    var s: Engine.State
    var fx: [Engine.Effect] = []

    mutating func handle(_ event: Engine.Event) {
        switch event {
        case .start(let start):
            begin(start)
            return
        case .configChanged(let config):
            s.config = config
            if s.phase == .speaking, s.capture == .monitor, !s.talkOverAllowed { closeMonitor() }
            return
        case .routeChanged(let route):
            s.route = route
            s.falseTriggers = 0
            return
        default:
            break
        }
        guard s.phase != .idle else { return }

        switch event {
        case .start, .configChanged, .routeChanged:
            break
        case .end:
            finish(.user)
        case .tap:
            tap()
        case .sendTapped:
            if s.phase == .listening { finishUtterance() }
        case .actionTapped(let label):
            actionTapped(label)
        case .speechStarted:
            s.speechActive = true
            speechStarted()
        case .speechEnded:
            s.speechActive = false
            speechEnded()
        case .words(let text):
            words(text)
        case .captureFailed:
            captureFailed()
        case .transcript(let text):
            guard s.phase == .sending else { return }
            cancel(.transcript)
            transcript(text)
        case .uploadFailed:
            guard s.phase == .sending else { return }
            cancel(.transcript)
            fx.append(.earcon(.error))
            guard let target = plainTarget() else {
                fx.append(.discardRecording)
                say(VoicePhrases.nowhereToSend, .system, then: .wait)
                return
            }
            fx.append(.sendVoiceNote(target.send))
            watch(target.convoID)
            if s.paused { wait() } else { say(VoicePhrases.noConnection, .system, then: .next) }
        case .sendFailed:
            fx.append(.earcon(.error))
            if s.phase == .waiting, !s.paused {
                say(VoicePhrases.notSentOffline, .system, then: .wait)
            } else {
                s.pendingNotice = VoicePhrases.notSentOffline
            }
        case .arrived(let entry):
            arrived(entry)
        case .resolved(let id, let expired):
            resolved(id, expired: expired)
        case .turnStarted(let convoID):
            s.working.insert(convoID)
        case .turnEnded(let convoID):
            s.working.remove(convoID)
        case .playbackFinished(let id):
            playbackFinished(id)
        case .timerFired(let id):
            guard s.timers.remove(id) != nil else { return }
            timerFired(id)
        case .interruption(.began), .appBackgrounded:
            pause()
        case .interruption(.ended(let shouldResume)):
            if shouldResume { resume() }
        case .appForegrounded:
            resume()
        }
    }

    // MARK: Start and end

    mutating func begin(_ start: Engine.Start) {
        guard s.phase == .idle else { return }
        var fresh = Engine.State()
        fresh.config = s.config
        fresh.route = s.route
        fresh.talkOverOffRoutes = s.talkOverOffRoutes
        s = fresh
        fx.append(.keepScreenAwake(true))
        timer(.idle, s.config.idleEnd)
        switch start {
        case .conversation(let id, let title, let boxName):
            s.convoID = id
            s.convoTitle = title
            s.boxName = boxName
            watch(id)
            listen()
        case .queue(let entries, let lastConvoID, let lastTitle, let lastBoxName):
            s.convoID = lastConvoID
            s.convoTitle = lastTitle
            s.boxName = lastBoxName
            if let lastConvoID { watch(lastConvoID) }
            let lead = VoicePhrases.needsYou(entries.count)
            guard let first = entries.first else {
                say(lead, .system, then: lastConvoID == nil ? .wait : .listen)
                return
            }
            s.inQueue = true
            s.queue = Array(entries.dropFirst())
            present(first, lead: lead)
        }
    }

    mutating func finish(_ reason: Engine.EndReason) {
        if s.phase == .sending, let target = plainTarget() {
            // Nothing he said is lost: it goes as a voice note.
            fx.append(.sendVoiceNote(target.send))
        } else if s.phase == .sending || s.confirm != nil {
            fx.append(.discardRecording)
        }
        for id in Engine.TimerID.allCases where s.timers.contains(id) { fx.append(.cancelTimer(id)) }
        if s.playing != nil { fx.append(.stopPlayback) }
        if s.ducked { fx.append(.restoreVolume) }
        if s.capture != nil { fx.append(.stopCapture(keep: false)) }
        if s.audioActive { fx.append(.releaseAudio) }
        fx.append(.keepScreenAwake(false))
        fx.append(.ended(reason))
        var fresh = Engine.State()
        fresh.config = s.config
        fresh.route = s.route
        fresh.talkOverOffRoutes = s.talkOverOffRoutes
        s = fresh
    }

    // MARK: Moving between phases

    /// `openMicrophone: false` plays with the microphone closed whatever
    /// the setting says (it has just failed).
    mutating func say(_ text: String, _ level: Engine.SpeechLevel, then: Engine.AfterPlayback, openMicrophone: Bool = true) {
        cancelListeningTimers()
        if s.capture == .record {
            fx.append(.stopCapture(keep: false))
            s.capture = nil
        }
        if !s.audioActive {
            fx.append(.activateAudio)
            s.audioActive = true
        }
        if s.playing != nil { fx.append(.stopPlayback) }
        if s.ducked {
            fx.append(.restoreVolume)
            s.ducked = false
        }
        let utterance = Engine.Utterance(id: s.nextUtterance, text: text, level: level)
        s.nextUtterance += 1
        s.playing = utterance
        s.after = then
        s.caption = text
        s.phase = .speaking
        s.heard = ""
        s.speechSeen = false
        s.askedGoOn = false
        s.falseTriggers = 0
        fx.append(.play(utterance))
        if s.talkOverAllowed, openMicrophone {
            if s.capture == nil {
                fx.append(.startCapture(.monitor))
                s.capture = .monitor
            }
        } else if s.capture == .monitor {
            fx.append(.stopCapture(keep: false))
            s.capture = nil
        }
    }

    /// Reads an entry out and makes it the thing answers are matched against.
    mutating func present(_ entry: VoiceEntry, lead: String? = nil) {
        s.current = entry
        s.level = 1
        s.section = 0
        s.said.insert(entry.id)
        watch(entry.convoID)
        timer(.idle, s.config.idleEnd)
        var text = VoicePhrases.reading(entry, inQueue: s.inQueue)
        var then = Engine.AfterPlayback.listen
        switch entry.subject {
        case .item(let item) where item.needsScreen:
            then = .next
        case .reply(let reply):
            s.working.remove(reply.convoID)
            if s.config.offerMore, s.moreHints < s.config.moreHintLimit, reply.more != nil || !reply.sections.isEmpty {
                text += " " + VoicePhrases.moreHint
                s.moreHints += 1
            }
        case .item, .prompt:
            break
        }
        if let lead { text = lead + " " + text }
        say(text, .short, then: then)
    }

    mutating func listen() {
        cancelListeningTimers()
        if !s.audioActive {
            fx.append(.activateAudio)
            s.audioActive = true
        }
        if s.playing != nil {
            fx.append(.stopPlayback)
            s.playing = nil
        }
        fx.append(.earcon(.micOpen))
        openRecording()
        s.phase = .listening
        s.caption = nil
        s.heard = ""
        s.speechSeen = false
        timer(.noSpeech, s.config.noSpeechTimeout)
        timer(.maxUtterance, s.config.maxUtterance)
    }

    mutating func openRecording() {
        switch s.capture {
        case .monitor: fx.append(.promoteCapture)
        case nil: fx.append(.startCapture(.record))
        case .record: break
        }
        s.capture = .record
    }

    /// Nothing to say and nobody talking: let go of the audio.
    mutating func wait() {
        cancelListeningTimers()
        if s.capture != nil {
            fx.append(.stopCapture(keep: false))
            s.capture = nil
        }
        if s.playing != nil {
            fx.append(.stopPlayback)
            s.playing = nil
        }
        if s.ducked {
            fx.append(.restoreVolume)
            s.ducked = false
        }
        s.caption = nil
        if !s.paused {
            if let notice = s.pendingNotice {
                s.pendingNotice = nil
                say(notice, .system, then: .wait)
                return
            }
            if !s.inbox.isEmpty {
                present(s.inbox.removeFirst())
                return
            }
        }
        if s.audioActive {
            fx.append(.releaseAudio)
            s.audioActive = false
        }
        s.phase = .waiting
    }

    /// The current thing is dealt with: what arrived meanwhile, then the
    /// rest of the queue, then waiting.
    mutating func next() {
        s.current = nil
        s.level = 0
        if !s.paused {
            if !s.inbox.isEmpty {
                present(s.inbox.removeFirst())
                return
            }
            if s.inQueue {
                if !s.queue.isEmpty {
                    present(s.queue.removeFirst())
                    return
                }
                s.inQueue = false
                say(VoicePhrases.queueDone, .system, then: s.convoID == nil ? .wait : .listen)
                return
            }
        }
        wait()
    }

    // MARK: Taps

    mutating func tap() {
        s.paused = false
        switch s.phase {
        case .speaking:
            if let confirm = s.confirm {
                cancelConfirm(confirm.kind == .sending ? VoicePhrases.cancelled : VoicePhrases.notSent)
            } else {
                interrupt(heard: "")
            }
        case .waiting:
            timer(.idle, s.config.idleEnd)
            listen()
        case .confirming:
            if let confirm = s.confirm {
                cancelConfirm(confirm.kind == .sending ? VoicePhrases.cancelled : VoicePhrases.notSent)
            }
        case .listening, .sending, .idle:
            break
        }
    }

    mutating func actionTapped(_ label: String) {
        guard let entry = s.current, entry.labels.contains(label) else { return }
        let send: Engine.Effect
        switch entry.subject {
        case .item(let item):
            send = .sendItemAction(itemID: item.id, label: label)
        case .prompt(let prompt):
            guard let option = prompt.options.first(where: { $0.label == label }) else { return }
            send = .sendPromptReply(convoID: prompt.convoID, seq: prompt.seq, choice: option.value, text: nil)
        case .reply:
            return
        }
        if s.confirm != nil || s.phase == .sending {
            cancel(.confirm)
            cancel(.transcript)
            s.confirm = nil
            fx.append(.discardRecording)
        }
        fx.append(send)
        fx.append(.earcon(.sent))
        timer(.idle, s.config.idleEnd)
        next()
    }

    // MARK: Hearing

    mutating func speechStarted() {
        switch s.phase {
        case .listening:
            s.speechSeen = true
            cancel(.noSpeech)
            cancel(.silence)
        case .speaking:
            guard s.capture == .monitor, s.talkOverAllowed, !s.ducked else { return }
            timer(.talkOverOnset, s.config.talkOverOnset)
        case .idle, .sending, .confirming, .waiting:
            break
        }
    }

    mutating func speechEnded() {
        switch s.phase {
        case .listening:
            guard s.speechSeen else { return }
            startSilenceTimer()
        case .speaking:
            cancel(.talkOverOnset)
        case .idle, .sending, .confirming, .waiting:
            break
        }
    }

    mutating func startSilenceTimer() {
        let isCommand = command(for: s.heard) != nil
        timer(.silence, isCommand ? s.config.commandSilence : s.config.endOfSpeechSilence)
    }

    mutating func words(_ text: String) {
        switch s.phase {
        case .listening:
            s.heard = text
            guard !VoiceText.words(text).isEmpty else { return }
            s.speechSeen = true
            cancel(.noSpeech)
            // The detector may already have reported the end (or nothing
            // at all): the words then start the count themselves.
            if !s.speechActive { startSilenceTimer() }
        case .speaking:
            guard s.capture == .monitor else { return }
            s.heard = text
            if s.ducked { interruptIfGenuine() }
        case .confirming:
            guard let confirm = s.confirm, let command = VoiceCommand.parse(text) else { return }
            switch (confirm.kind, command) {
            case (_, .yes):
                commitConfirm()
            case (.sending, .cancel), (.sending, .no), (.sending, .stop):
                cancelConfirm(VoicePhrases.cancelled)
            case (.didYouMean, .cancel), (.didYouMean, .no), (.didYouMean, .stop):
                cancelConfirm(VoicePhrases.notSent)
            default:
                break
            }
        case .idle, .sending, .waiting:
            break
        }
    }

    /// Words under a ducked clip stop it, unless they are the clip's own.
    mutating func interruptIfGenuine() {
        guard let playing = s.playing, !VoiceText.words(s.heard).isEmpty,
              !Engine.isEcho(s.heard, of: playing.text) else { return }
        interrupt(heard: s.heard)
    }

    /// The clip stops and the engine is listening. With `heard` empty this
    /// is a tap; otherwise he is already mid-sentence and the recording
    /// keeps the half second before he started.
    mutating func interrupt(heard: String) {
        cancelListeningTimers()
        fx.append(.stopPlayback)
        if s.ducked {
            fx.append(.restoreVolume)
            s.ducked = false
        }
        s.playing = nil
        s.caption = nil
        s.falseTriggers = 0
        if !s.audioActive {
            fx.append(.activateAudio)
            s.audioActive = true
        }
        if heard.isEmpty { fx.append(.earcon(.micOpen)) }
        openRecording()
        s.phase = .listening
        s.heard = heard
        s.speechSeen = !heard.isEmpty
        timer(.idle, s.config.idleEnd)
        timer(.maxUtterance, s.config.maxUtterance)
        if heard.isEmpty {
            timer(.noSpeech, s.config.noSpeechTimeout)
        } else if !s.speechActive {
            startSilenceTimer()
        }
    }

    mutating func captureFailed() {
        fx.append(.earcon(.error))
        s.capture = nil
        cancel(.talkOverOnset)
        cancel(.talkOverWords)
        if s.ducked {
            fx.append(.restoreVolume)
            s.ducked = false
        }
        if s.phase == .listening { say(VoicePhrases.microphoneFailed, .system, then: .wait, openMicrophone: false) }
    }

    mutating func closeMonitor() {
        cancel(.talkOverOnset)
        cancel(.talkOverWords)
        if s.ducked {
            fx.append(.restoreVolume)
            s.ducked = false
        }
        fx.append(.stopCapture(keep: false))
        s.capture = nil
    }

    // MARK: The end of an utterance

    /// The command these words are, given what is on offer: a label wins
    /// over a command word (an item may offer "Skip"), and "yes" and "no"
    /// are commands only to a question the engine itself asked.
    func command(for words: String) -> VoiceCommand? {
        guard let command = VoiceCommand.parse(words) else { return nil }
        let heard = VoiceText.words(words)
        if s.labels.contains(where: { VoiceText.words($0) == heard }) { return nil }
        if command == .yes || command == .no, s.confirm == nil, !s.askedGoOn { return nil }
        return command
    }

    mutating func finishUtterance() {
        cancel(.noSpeech)
        cancel(.silence)
        cancel(.maxUtterance)
        timer(.idle, s.config.idleEnd)
        let command = command(for: s.heard)
        if let confirm = s.confirm {
            // He talked over "Sending: Go" or "Did you mean Go?".
            s.confirm = nil
            fx.append(.discardRecording)
            switch command {
            case .yes?:
                fx.append(.stopCapture(keep: false))
                s.capture = nil
                fx.append(confirm.send)
                fx.append(.earcon(.sent))
                next()
                return
            case .cancel?, .no?, .stop?:
                fx.append(.stopCapture(keep: false))
                s.capture = nil
                say(confirm.kind == .sending ? VoicePhrases.cancelled : VoicePhrases.notSent, .system, then: .listen)
                return
            default:
                break   // not sent; what he said instead is handled below
            }
        }
        if let command {
            fx.append(.stopCapture(keep: false))
            s.capture = nil
            run(command)
            return
        }
        fx.append(.stopCapture(keep: true))
        s.capture = nil
        fx.append(.upload)
        s.phase = .sending
        timer(.transcript, s.config.transcriptTimeout)
    }

    mutating func run(_ command: VoiceCommand) {
        switch command {
        case .repeat: repeatCurrent()
        case .more: more()
        case .skip: next()
        case .stop, .cancel: wait()
        case .yes: if s.askedGoOn { more() } else { wait() }
        case .no: wait()
        }
    }

    func readable(_ entry: VoiceEntry) -> (more: String?, sections: [String]) {
        switch entry.subject {
        case .reply(let reply): return (reply.more, reply.sections)
        case .item(let item): return (nil, item.needsScreen ? [] : item.sections)
        case .prompt: return (nil, [])
        }
    }

    mutating func more() {
        guard let entry = s.current else {
            say(VoicePhrases.wholeMessage, .system, then: .listen)
            return
        }
        let parts = readable(entry)
        if s.level <= 1, let more = parts.more {
            s.level = 2
            say(more, .more, then: .listen)
            return
        }
        let index = s.level >= 3 ? s.section + 1 : 0
        guard index < parts.sections.count else {
            say(VoicePhrases.wholeMessage, .system, then: .listen)
            return
        }
        s.level = 3
        s.section = index
        saySection(parts.sections, index)
    }

    mutating func saySection(_ sections: [String], _ index: Int) {
        let isLast = index == sections.count - 1
        say(isLast ? sections[index] : sections[index] + " " + VoicePhrases.goOn, .section, then: .listen)
        s.askedGoOn = !isLast
    }

    mutating func repeatCurrent() {
        guard let entry = s.current else {
            say(VoicePhrases.nothingToRepeat, .system, then: .listen)
            return
        }
        let parts = readable(entry)
        if s.level == 2, let more = parts.more {
            say(more, .more, then: .listen)
        } else if s.level >= 3, s.section < parts.sections.count {
            saySection(parts.sections, s.section)
        } else {
            var then = Engine.AfterPlayback.listen
            if case .item(let item) = entry.subject, item.needsScreen { then = .next }
            say(VoicePhrases.reading(entry, inQueue: s.inQueue), .short, then: then)
        }
    }

    // MARK: The transcript

    /// Where a plain spoken reply goes: the item just read, else the
    /// conversation of the reply or prompt just read, else the
    /// conversation voice mode was started on.
    func plainTarget() -> (send: Engine.SendTarget, convoID: String)? {
        switch s.current?.subject {
        case .item(let item)? where !item.needsScreen:
            return (.item(item.id), item.convoID)
        case .prompt(let prompt)?:
            return (.conversation(prompt.convoID), prompt.convoID)
        case .reply(let reply)?:
            return (.conversation(reply.convoID), reply.convoID)
        case .item?, nil:
            return s.convoID.map { (.conversation($0), $0) }
        }
    }

    mutating func sendPlain(announce: Bool) {
        guard let target = plainTarget() else {
            fx.append(.discardRecording)
            say(VoicePhrases.nowhereToSend, .system, then: .wait)
            return
        }
        fx.append(.sendVoiceNote(target.send))
        sent(to: target.convoID, announce: announce)
    }

    mutating func sent(to convoID: String, announce: Bool) {
        fx.append(.earcon(.sent))
        watch(convoID)
        if s.paused {
            next()
        } else if announce {
            say(VoicePhrases.sent, .system, then: .next)
        } else if s.working.contains(convoID) {
            say(VoicePhrases.busy(s.current?.boxName ?? s.boxName), .system, then: .next)
        } else {
            next()
        }
    }

    mutating func transcript(_ raw: String?) {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // No transcript in time: a plain voice note, and say so. Paused
        // (a call came in mid-send): the same, silently.
        guard !text.isEmpty, !s.paused else {
            sendPlain(announce: !s.paused)
            return
        }
        if let command = command(for: text) {
            fx.append(.discardRecording)
            run(command)
            return
        }
        guard let entry = s.current else {
            sendPlain(announce: false)
            return
        }
        switch entry.subject {
        case .prompt(let prompt) where prompt.isPermission:
            guard let verdict = ActionLabelMatcher.permissionVerdict(text), let option = prompt.option(for: verdict) else {
                fx.append(.discardRecording)
                say(VoicePhrases.allowOrDeny, .system, then: .listen)
                return
            }
            let send = Engine.Effect.sendPromptReply(convoID: prompt.convoID, seq: prompt.seq, choice: option.value, text: nil)
            if verdict == .deny {
                // Denying by mistake costs nothing: no confirmation.
                fx.append(.discardRecording)
                fx.append(send)
                fx.append(.earcon(.sent))
                say(VoicePhrases.denied, .system, then: .next)
            } else {
                // Allowing by mistake does: always asked, whatever was heard.
                startConfirm(.didYouMean, label: option.label, send: send)
            }
        case .prompt(let prompt):
            func reply(_ label: String) -> Engine.Effect {
                let value = prompt.options.first { $0.label == label }?.value ?? label
                return .sendPromptReply(convoID: prompt.convoID, seq: prompt.seq, choice: value, text: nil)
            }
            switch ActionLabelMatcher.match(text, labels: prompt.labels) {
            case .clear(let label): startConfirm(.sending, label: label, send: reply(label))
            case .unsure(let label): startConfirm(.didYouMean, label: label, send: reply(label))
            case .none:
                fx.append(.discardRecording)
                fx.append(.sendPromptReply(convoID: prompt.convoID, seq: prompt.seq, choice: nil, text: text))
                sent(to: prompt.convoID, announce: false)
            }
        case .item(let item) where !item.needsScreen && !item.labels.isEmpty:
            switch ActionLabelMatcher.match(text, labels: item.labels) {
            case .clear(let label):
                startConfirm(.sending, label: label, send: .sendItemAction(itemID: item.id, label: label))
            case .unsure(let label):
                startConfirm(.didYouMean, label: label, send: .sendItemAction(itemID: item.id, label: label))
            case .none:
                sendPlain(announce: false)
            }
        case .item, .reply:
            sendPlain(announce: false)
        }
    }

    // MARK: Confirming

    mutating func startConfirm(_ kind: Engine.Confirm.Kind, label: String, send: Engine.Effect) {
        s.confirm = Engine.Confirm(kind: kind, label: label, send: send)
        say(kind == .sending ? VoicePhrases.sending(label) : VoicePhrases.didYouMean(label), .system, then: .confirm)
    }

    mutating func commitConfirm() {
        guard let confirm = s.confirm else { return }
        cancel(.confirm)
        s.confirm = nil
        fx.append(confirm.send)
        fx.append(.discardRecording)
        fx.append(.earcon(.sent))
        timer(.idle, s.config.idleEnd)
        next()
    }

    mutating func cancelConfirm(_ phrase: String, then: Engine.AfterPlayback = .listen) {
        cancel(.confirm)
        s.confirm = nil
        fx.append(.discardRecording)
        say(phrase, .system, then: then)
    }

    // MARK: Things arriving and going

    mutating func arrived(_ entry: VoiceEntry) {
        guard !s.said.contains(entry.id), !s.inbox.contains(where: { $0.id == entry.id }),
              !s.queue.contains(where: { $0.id == entry.id }) else { return }
        if case .reply(let reply) = entry.subject { s.working.remove(reply.convoID) }
        if s.paused {
            s.inbox.append(entry)
            return
        }
        switch s.phase {
        case .waiting:
            present(entry)
        case .listening where !s.speechSeen && s.confirm == nil:
            present(entry)
        case .idle, .listening, .sending, .confirming, .speaking:
            s.inbox.append(entry)
        }
    }

    mutating func resolved(_ id: String, expired: Bool) {
        s.inbox.removeAll { $0.id == id }
        s.queue.removeAll { $0.id == id }
        guard let current = s.current, current.id == id else { return }
        var wasPermission = false
        if case .prompt(let prompt) = current.subject { wasPermission = prompt.isPermission }
        if s.confirm != nil {
            cancel(.confirm)
            s.confirm = nil
            fx.append(.discardRecording)
        }
        // Mid-send or mid-sentence: what he is saying goes as a plain
        // message; only the thing it would have answered is gone.
        if s.phase == .sending || (s.phase == .listening && s.speechSeen) || s.paused {
            s.current = nil
            return
        }
        if expired, wasPermission {
            s.current = nil
            say(VoicePhrases.permissionExpired, .system, then: .next)
        } else if s.phase == .waiting {
            s.current = nil
        } else {
            next()
        }
    }

    // MARK: Playback and timers

    mutating func playbackFinished(_ id: Int) {
        guard s.phase == .speaking, s.playing?.id == id else { return }
        cancel(.talkOverOnset)
        cancel(.talkOverWords)
        if s.ducked {
            fx.append(.restoreVolume)
            s.ducked = false
        }
        s.playing = nil
        if let notice = s.pendingNotice {
            s.pendingNotice = nil
            let after = s.after
            let askedGoOn = s.askedGoOn
            say(notice, .system, then: after)
            s.askedGoOn = askedGoOn
            return
        }
        switch s.after {
        case .listen:
            if s.current == nil, !s.inbox.isEmpty {
                present(s.inbox.removeFirst())
            } else {
                let askedGoOn = s.askedGoOn
                listen()
                s.askedGoOn = askedGoOn
            }
        case .confirm:
            guard let confirm = s.confirm else {
                listen()
                return
            }
            s.phase = .confirming
            s.caption = nil
            s.heard = ""
            if s.capture == nil {
                fx.append(.startCapture(.monitor))
                s.capture = .monitor
            }
            timer(.confirm, confirm.kind == .sending ? s.config.confirmWindow : s.config.noSpeechTimeout)
        case .wait:
            wait()
        case .next:
            next()
        }
    }

    mutating func timerFired(_ id: Engine.TimerID) {
        switch id {
        case .idle:
            finish(.idle)
        case .noSpeech:
            guard s.phase == .listening else { return }
            if s.confirm != nil {
                s.confirm = nil
                fx.append(.discardRecording)
            }
            wait()
        case .silence, .maxUtterance:
            guard s.phase == .listening else { return }
            finishUtterance()
        case .transcript:
            guard s.phase == .sending else { return }
            transcript(nil)
        case .confirm:
            guard s.phase == .confirming, let confirm = s.confirm else { return }
            if confirm.kind == .sending {
                commitConfirm()
            } else {
                cancelConfirm(VoicePhrases.notSent, then: .wait)
            }
        case .talkOverOnset:
            guard s.phase == .speaking, s.capture == .monitor else { return }
            fx.append(.duck)
            s.ducked = true
            timer(.talkOverWords, s.config.talkOverWords)
            interruptIfGenuine()
        case .talkOverWords:
            guard s.phase == .speaking, s.ducked else { return }
            // A cough, a door, or the clip hearing itself: carry on.
            fx.append(.restoreVolume)
            s.ducked = false
            s.heard = ""
            s.falseTriggers += 1
            if s.falseTriggers >= s.config.falseTriggerLimit {
                s.falseTriggers = 0
                s.talkOverOffRoutes.insert(s.route)
                s.pendingNotice = VoicePhrases.talkOverOff
                if s.capture == .monitor {
                    fx.append(.stopCapture(keep: false))
                    s.capture = nil
                }
            }
        }
    }

    // MARK: Pausing

    /// A call, Siri, or the app leaving the front: stop everything and let
    /// go of the audio. A send already on its way carries on.
    mutating func pause() {
        guard !s.paused else { return }
        s.paused = true
        guard s.phase != .sending else { return }
        if s.confirm != nil {
            cancel(.confirm)
            s.confirm = nil
            fx.append(.discardRecording)
        }
        // Cut off mid-sentence: it is said again on return.
        if s.phase == .speaking, let entry = s.current, s.playing?.level == .short {
            s.inbox.insert(entry, at: 0)
            s.said.remove(entry.id)
            s.current = nil
        }
        wait()
    }

    mutating func resume() {
        guard s.paused else { return }
        s.paused = false
        if s.phase == .waiting { wait() }
    }

    // MARK: Small things

    mutating func watch(_ convoID: String) {
        guard s.watched.insert(convoID).inserted else { return }
        fx.append(.watch(convoID: convoID))
    }

    mutating func timer(_ id: Engine.TimerID, _ interval: TimeInterval) {
        s.timers.insert(id)
        fx.append(.startTimer(id, interval))
    }

    mutating func cancel(_ id: Engine.TimerID) {
        guard s.timers.remove(id) != nil else { return }
        fx.append(.cancelTimer(id))
    }

    mutating func cancelListeningTimers() {
        for id in [Engine.TimerID.noSpeech, .silence, .maxUtterance, .talkOverOnset, .talkOverWords] { cancel(id) }
    }
}
