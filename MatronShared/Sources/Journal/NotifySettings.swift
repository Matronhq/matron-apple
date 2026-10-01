import Foundation

/// What may push to the user's devices (journal spec 2026-10-01
/// notification settings): a mode with its event switches, and the
/// per-conversation overrides — the part the journal syncs per user and
/// sends live as `{kind:"notify", settings}`. The per-device level is not in
/// here: it belongs to one device and rides only `NotifyView`.
public struct NotifySettings: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        case coordinator
        case all
        case custom
    }

    /// The event switches, in the order the settings screen lists them.
    public enum Event: String, CaseIterable, Sendable {
        case prompts
        case questions
        case coordinatorDone = "coordinator_done"
        case otherDone = "other_done"
        case stopped
        case rooms
        case activity
    }

    /// One conversation's own level; `nil` on an override means "follow the
    /// mode". The journal's `none` is `.silent` here: a case named `none`
    /// would read as `Optional.none` wherever a `ConvoLevel?` is expected.
    public enum ConvoLevel: String, CaseIterable, Sendable {
        case all
        case needsMe = "needs_me"
        case silent = "none"
    }

    /// One conversation's row in `convos`: a level, a mute, or both.
    public struct ConvoOverride: Equatable, Sendable {
        public var convoID: String
        public var level: ConvoLevel?
        public var muteUntil: Date?

        public init(convoID: String, level: ConvoLevel? = nil, muteUntil: Date? = nil) {
            self.convoID = convoID
            self.level = level
            self.muteUntil = muteUntil
        }

        /// The mute only counts while it runs; the journal lists a lapsed one
        /// until the next read, and so does this copy.
        public func isMuted(at now: Date) -> Bool {
            muteUntil.map { $0 > now } ?? false
        }

        /// Still an override at `now`: a level, or a mute that has not run out.
        public func isActive(at now: Date) -> Bool {
            level != nil || isMuted(at: now)
        }
    }

    public var mode: Mode
    public var events: [Event: Bool]
    /// Coordinator mode with no Coordinator set acts as "Every session".
    public var hasCoordinator: Bool
    public var convos: [ConvoOverride]

    public init(mode: Mode, events: [Event: Bool], hasCoordinator: Bool, convos: [ConvoOverride]) {
        self.mode = mode
        self.events = events
        self.hasCoordinator = hasCoordinator
        self.convos = convos
    }

    /// The switches a preset fixes; `nil` for `.custom`, which keeps its own.
    /// Mirrors the journal's `PRESETS` (src/notify.js).
    public static func preset(_ mode: Mode) -> [Event: Bool]? {
        switch mode {
        case .coordinator:
            return [.prompts: true, .questions: true, .coordinatorDone: true, .otherDone: false,
                    .stopped: false, .rooms: false, .activity: false]
        case .all:
            return [.prompts: true, .questions: true, .coordinatorDone: true, .otherDone: true,
                    .stopped: true, .rooms: false, .activity: false]
        case .custom:
            return nil
        }
    }

    /// Whether one switch is on. `prompts` is always on: an unanswered
    /// prompt blocks an agent.
    public func isOn(_ event: Event) -> Bool {
        event == .prompts || events[event] == true
    }

    /// The override for one conversation, as stored (lapsed mutes included).
    public func override(for convoID: String) -> ConvoOverride? {
        convos.first { $0.convoID == convoID }
    }

    /// Decodes the `settings` object of a `notify` frame, or the synced part
    /// of a `GET`/`PUT /notify` answer. `nil` when the mode is missing or
    /// unknown; an event this build does not know is ignored, and a missing
    /// one reads as off (`prompts` excepted).
    public static func decode(_ obj: [String: Any]) -> NotifySettings? {
        guard let rawMode = obj["mode"] as? String, let mode = Mode(rawValue: rawMode) else { return nil }
        let rawEvents = obj["events"] as? [String: Any] ?? [:]
        var events: [Event: Bool] = [:]
        for event in Event.allCases {
            events[event] = (rawEvents[event.rawValue] as? Bool) ?? false
        }
        events[.prompts] = true
        let convos = (obj["convos"] as? [[String: Any]] ?? []).compactMap { row -> ConvoOverride? in
            guard let id = row["convo_id"] as? String, !id.isEmpty else { return nil }
            let level = (row["level"] as? String).flatMap(ConvoLevel.init(rawValue:))
            let muteUntil = (row["mute_until"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue / 1000)
            }
            return ConvoOverride(convoID: id, level: level, muteUntil: muteUntil)
        }
        return NotifySettings(mode: mode, events: events,
                              hasCoordinator: obj["has_coordinator"] as? Bool ?? false, convos: convos)
    }
}

/// What this device may push, on top of everything above: all of it, only
/// what needs the user (prompts and questions), or nothing.
public enum NotifyDeviceLevel: String, CaseIterable, Sendable {
    case all
    case needsMe = "needs_me"
    case off
}

/// The whole `GET /notify` answer: the synced settings plus this device's
/// own level.
public struct NotifyView: Equatable, Sendable {
    public var settings: NotifySettings
    public var deviceLevel: NotifyDeviceLevel

    public init(settings: NotifySettings, deviceLevel: NotifyDeviceLevel) {
        self.settings = settings
        self.deviceLevel = deviceLevel
    }

    public static func decode(_ obj: [String: Any]) -> NotifyView? {
        guard let settings = NotifySettings.decode(obj) else { return nil }
        let level = (obj["device_level"] as? String).flatMap(NotifyDeviceLevel.init(rawValue:)) ?? .all
        return NotifyView(settings: settings, deviceLevel: level)
    }
}

/// One `PUT /notify`. Each case is one change the user makes, so a failed
/// write rolls back exactly that change.
public enum NotifyChange: Equatable, Sendable {
    case mode(NotifySettings.Mode)
    /// Switching an event while on a preset moves the user to custom,
    /// starting from that preset.
    case event(NotifySettings.Event, Bool)
    case deviceLevel(NotifyDeviceLevel)
    /// `nil` = follow the mode. Leaves any mute as it is.
    case convoLevel(convoID: String, NotifySettings.ConvoLevel?)
    /// `nil` = unmute. Leaves the level as it is.
    case convoMute(convoID: String, until: Date?)
    /// Drops the conversation's override entirely: level and mute.
    case clearConvo(convoID: String)

    /// The `PUT /notify` body. Explicit `null`s clear a level or a mute; an
    /// absent key leaves it as it is.
    public var body: [String: Any] {
        switch self {
        case .mode(let mode):
            return ["mode": mode.rawValue]
        case .event(let event, let on):
            return ["events": [event.rawValue: on]]
        case .deviceLevel(let level):
            return ["device_level": level.rawValue]
        case .convoLevel(let convoID, let level):
            return ["convo": ["convo_id": convoID, "level": level.map { $0.rawValue as Any } ?? NSNull()]]
        case .convoMute(let convoID, let until):
            return ["convo": ["convo_id": convoID, "mute_until": until.map { Self.epochMillis($0) as Any } ?? NSNull()]]
        case .clearConvo(let convoID):
            return ["convo": ["convo_id": convoID, "level": NSNull(), "mute_until": NSNull()]]
        }
    }

    /// The journal validates `mute_until` as an integer.
    static func epochMillis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// The change as the journal will apply it (src/notify.js
    /// `setNotifyPrefs` / `setConvoNotify`), for the optimistic copy shown
    /// while the `PUT` is in flight.
    public func applied(to view: NotifyView) -> NotifyView {
        var view = view
        switch self {
        case .mode(let mode):
            view.settings.mode = mode
            // Custom keeps whatever switches were showing.
            if let preset = NotifySettings.preset(mode) { view.settings.events = preset }
        case .event(let event, let on):
            view.settings.mode = .custom
            view.settings.events[event] = event == .prompts ? true : on
        case .deviceLevel(let level):
            view.deviceLevel = level
        case .convoLevel(let convoID, let level):
            view.settings.convos = Self.updating(view.settings.convos, convoID) { $0.level = level }
        case .convoMute(let convoID, let until):
            view.settings.convos = Self.updating(view.settings.convos, convoID) { $0.muteUntil = until }
        case .clearConvo(let convoID):
            view.settings.convos.removeAll { $0.convoID == convoID }
        }
        return view
    }

    /// Edits one conversation's row in place (a new one goes first, as the
    /// journal lists the latest change first); a row left with neither a
    /// level nor a mute is dropped, as the journal deletes it.
    private static func updating(_ convos: [NotifySettings.ConvoOverride], _ convoID: String,
                                 _ edit: (inout NotifySettings.ConvoOverride) -> Void) -> [NotifySettings.ConvoOverride] {
        var convos = convos
        var row = convos.first { $0.convoID == convoID } ?? NotifySettings.ConvoOverride(convoID: convoID)
        edit(&row)
        convos.removeAll { $0.convoID == convoID }
        if row.level != nil || row.muteUntil != nil { convos.insert(row, at: 0) }
        return convos
    }
}

/// The mute choices a conversation's Notifications menu offers.
public enum NotifyMuteDuration: CaseIterable, Sendable {
    case oneHour
    case eightHours
    case untilTomorrowMorning

    /// When a mute started at `now` ends. "Tomorrow" is the next calendar
    /// day in `calendar`'s (the device's) time zone.
    public func end(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(60 * 60)
        case .eightHours:
            return now.addingTimeInterval(8 * 60 * 60)
        case .untilTomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
    }
}
