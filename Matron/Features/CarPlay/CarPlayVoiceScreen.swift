import Foundation
import MatronChat
import MatronVoice

/// Engine state as the car's voice-control screen draws it. The car
/// display never shows what a reply says: only which state voice mode is
/// in, the conversation's name and box, and at most two buttons. Nothing
/// here imports CarPlay, so it is tested without a car.
enum CarPlayVoiceScreen {
    /// The voice-control template takes at most five states.
    enum StateID: String, CaseIterable, Sendable {
        case listening, sending, working, speaking, ready
    }

    enum Button: Equatable, Sendable {
        /// One of the current thing's two answers.
        case label(String)
        case skip
        case stop
        /// Opens the microphone.
        case talk
        /// Turns down a pending "Sending: Go".
        case cancel

        var title: String {
            switch self {
            case .label(let label): return label
            case .skip: return "Skip"
            case .stop: return "Stop"
            case .talk: return "Talk"
            case .cancel: return "Cancel"
            }
        }

        /// What the engine is told when the button is pressed.
        var event: VoiceModeEngine.Event {
            switch self {
            case .label(let label): return .actionTapped(label)
            case .skip: return .commandTapped(.skip)
            case .stop: return .commandTapped(.stop)
            case .talk, .cancel: return .tap
            }
        }
    }

    /// Why there is no sitting to draw.
    enum Idle: Equatable, Sendable {
        /// Voice mode has ended, or has not begun: Talk starts it.
        case ready
        case signedOut
        /// The iPhone is recording a voice note or running voice mode.
        case microphoneBusy
        /// This iPhone cannot run voice mode.
        case unavailable
    }

    /// Everything fixed while the template is on the display: a state's
    /// titles cannot change once it is shown, so a new layout means a new
    /// template.
    struct Layout: Equatable, Sendable {
        /// Shortest first; the car picks the longest that fits.
        var titles: [StateID: [String]]
        var buttons: [StateID: [Button]]
    }

    struct Model: Equatable, Sendable {
        var active: StateID
        var layout: Layout
    }

    /// The most buttons a state is given, whatever the car allows.
    static let buttonLimit = 2

    static func model(_ state: VoiceModeEngine.State) -> Model {
        let active: StateID
        switch state.phase {
        case .idle, .waiting: active = state.isAgentWorking ? .working : .ready
        // "Did you mean Go?" has been asked and the microphone is open for
        // the answer.
        case .listening, .confirming: active = .listening
        case .sending: active = .sending
        case .speaking: active = .speaking
        }
        return Model(active: active, layout: Layout(titles: titles(state), buttons: buttons(state)))
    }

    static func model(_ idle: Idle) -> Model {
        let title: [String]
        var buttons: [Button] = []
        switch idle {
        case .ready:
            title = ["Ready", "Tap Talk to speak"]
            buttons = [.talk]
        case .signedOut:
            title = ["Sign in on iPhone", "Open Matron on your iPhone to sign in"]
        case .microphoneBusy:
            title = ["In use on iPhone", "Matron is using the microphone on your iPhone"]
            buttons = [.talk]
        case .unavailable:
            title = ["Unavailable", "Voice mode is unavailable on this iPhone"]
        }
        var layout = Layout(titles: [:], buttons: [:])
        for id in StateID.allCases { layout.titles[id] = [id.rawValue.capitalized] }
        layout.titles[.ready] = title
        layout.buttons[.ready] = buttons
        return Model(active: .ready, layout: layout)
    }

    private static func titles(_ state: VoiceModeEngine.State) -> [StateID: [String]] {
        let conversation = state.title
        let box = state.current?.boxName ?? state.boxName
        func named(_ short: String, _ long: String?) -> [String] {
            guard let long else { return [short] }
            return [short, long]
        }
        return [
            .listening: named("Listening", conversation.isEmpty ? nil : "Listening: \(conversation)"),
            .sending: ["Sending"],
            .working: named("Working", box.map { "\($0) is working" }),
            .speaking: named("Speaking", box.map { "\($0) is speaking" }),
            .ready: named("Ready", conversation.isEmpty ? "Tap Talk to speak" : "Ready: \(conversation)"),
        ]
    }

    /// The current thing's answers when there are exactly two, otherwise
    /// Skip and Stop. Three or four answers are given by voice only: they
    /// are said, not shown.
    private static func buttons(_ state: VoiceModeEngine.State) -> [StateID: [Button]] {
        let open: [Button]
        if state.confirm != nil {
            open = [.cancel]
        } else if state.labels.count == buttonLimit {
            open = state.labels.map(Button.label)
        } else {
            open = (state.current == nil ? [] : [.skip]) + [.stop]
        }
        return [.listening: open, .speaking: open, .sending: [], .working: [.talk], .ready: [.talk]]
    }
}

/// One row of the car's conversation list.
struct CarPlayChatRow: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let boxName: String?
    let isWorking: Bool

    /// The line under the title: the box, and whether it is working.
    var detail: String? {
        let parts = [boxName, isWorking ? "Working" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum CarPlayChats {
    /// A list on the car display holds at most this many rows.
    static let rowLimit = 12

    /// The most recently used conversations, newest first as given.
    static func rows(_ conversations: [QueueConversation]) -> [CarPlayChatRow] {
        conversations.prefix(rowLimit).map { conversation in
            let title = SessionTag.splitTitle(conversation.title).title
            return CarPlayChatRow(id: conversation.id, title: title.isEmpty ? "Conversation" : title,
                                  boxName: conversation.boxName, isWorking: conversation.sessionState == "running")
        }
    }
}
