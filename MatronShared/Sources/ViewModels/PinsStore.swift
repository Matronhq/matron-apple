import Foundation
import os
import MatronChat
import MatronJournal
import MatronModels

/// The session's pinned desk chats (journal "Pinned desk chats"): the Mac's
/// nav-column entries under the Coordinator, the iPhone's Pinned section,
/// and Settings → Pinned chats all read this one list. Reads `GET /pins` on
/// every connect (the live frame has no replay) and applies live `pins`
/// frames as they land. Writes go to the journal and its answer — the whole
/// list — replaces what is shown; a reorder shows at once and a failed one
/// puts the old order back.
@Observable @MainActor
public final class PinsStore {
    private static let logger = Logger(subsystem: "chat.matron", category: "pins")

    /// In the user's order. Empty until the first answer.
    public private(set) var pins: [ConvoPin] = []
    public private(set) var limit = ConvoPin.defaultLimit
    /// `nil` until the journal answers; `false` once `GET /pins` 404s — a
    /// journal predating pins, where nothing is drawn and Settings says so.
    public private(set) var isSupported: Bool?
    /// The last failed write, in the user's words. Cleared by the next
    /// success.
    public private(set) var errorMessage: String?
    /// The user's boxes by device id, for naming a pin's box in its
    /// successor hint.
    public private(set) var boxNames: [Int64: String] = [:]
    /// The Coordinator conversation, which has its own entry and is never
    /// offered for pinning. Set by the app from the Coordinator setting.
    public var coordinatorConvoID: String?

    private let api: any PinsProviding
    private let updates: @Sendable () -> AsyncStream<[ConvoPin]>
    private let connectionStates: @Sendable () -> AsyncStream<SyncConnectionState>
    private let boxNameUpdates: @Sendable () -> AsyncStream<[Int64: String]>
    /// Bumped whenever `pins` takes a newer answer (a live frame or a write's
    /// reply). A `GET` that started before is older news and is dropped — the
    /// `CoordinatorSync` epoch rule.
    private var epoch = 0
    private var updatesTask: Task<Void, Never>?
    private var statesTask: Task<Void, Never>?
    private var boxNamesTask: Task<Void, Never>?

    public init(api: any PinsProviding,
                updates: @escaping @Sendable () -> AsyncStream<[ConvoPin]>,
                connectionStates: @escaping @Sendable () -> AsyncStream<SyncConnectionState>,
                boxNames: @escaping @Sendable () -> AsyncStream<[Int64: String]> = { AsyncStream { $0.finish() } }) {
        self.api = api
        self.updates = updates
        self.connectionStates = connectionStates
        self.boxNameUpdates = boxNames
    }

    /// "New session on box-b — move pin here?", or `nil` when the
    /// pin offers no successor. A missing pin offers only Move pin… and
    /// Unpin, so it shows none either.
    public func successorHint(for pin: ConvoPin) -> String? {
        guard pin.successor != nil, !pin.missing else { return nil }
        return Self.successorHint(boxName: pin.deviceID.flatMap { boxNames[$0] })
    }

    public nonisolated static func successorHint(boxName: String?) -> String {
        let name = boxName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "New session on \(name.isEmpty ? "this box" : name) — move pin here?"
    }

    /// The pinned conversation ids, for hiding them from the Conversations list.
    public var pinnedIDs: Set<String> { Set(pins.map(\.convoID)) }

    public var isFull: Bool { pins.count >= limit }

    public func pin(for convoID: String) -> ConvoPin? {
        pins.first { $0.convoID == convoID }
    }

    public func isPinned(_ convoID: String) -> Bool { pin(for: convoID) != nil }

    /// Whether "Pin to sidebar…" is offered for `convoID`: a journal with
    /// pins, room for one more, not pinned already, and not the Coordinator.
    public func canPin(_ convoID: String) -> Bool {
        isSupported == true && !isFull && !isPinned(convoID)
            && !(coordinatorConvoID.map { !$0.isEmpty && $0 == convoID } ?? false)
    }

    public func start() {
        guard updatesTask == nil else { return }
        let stream = updates()
        updatesTask = Task { [weak self] in
            for await pins in stream {
                guard !Task.isCancelled else { return }
                self?.applyLive(pins)
            }
        }
        // The state stream replays `.running` once caught up, cold start
        // included, so this is also the first read.
        let states = connectionStates()
        statesTask = Task { [weak self] in
            for await state in states {
                guard !Task.isCancelled else { return }
                if case .running = state { await self?.refresh() }
            }
        }
        let names = boxNameUpdates()
        boxNamesTask = Task { [weak self] in
            for await map in names {
                guard !Task.isCancelled else { return }
                if self?.boxNames != map { self?.boxNames = map }
            }
        }
    }

    public func stop() {
        updatesTask?.cancel()
        statesTask?.cancel()
        boxNamesTask?.cancel()
        updatesTask = nil
        statesTask = nil
        boxNamesTask = nil
        // A `GET` still in flight must not land after this.
        epoch += 1
    }

    /// `GET /pins`. A transport failure keeps what is shown.
    public func refresh() async {
        let startEpoch = epoch
        do {
            let answer = try await api.pins()
            guard epoch == startEpoch else {
                Self.logger.debug("dropping a GET /pins answer superseded by a newer one")
                return
            }
            isSupported = true
            adopt(answer)
        } catch JournalAPIError.notFound {
            guard epoch == startEpoch else { return }
            isSupported = false
            pins = []
        } catch {
            Self.logger.warning("GET /pins failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Changes

    /// Pins `convoID` under `label` (clamped to the journal's rule). Returns
    /// the error to show, or `nil` on success.
    @discardableResult
    public func pin(_ convoID: String, label: String, emoji: String) async -> String? {
        let label = ConvoPin.clampLabel(label)
        return await write { try await $0.setPin(convoID, label: label.isEmpty ? ConvoPin.labelFallback : label,
                                                 emoji: ConvoPin.clampEmoji(emoji)) }
    }

    /// Renames a pin or changes its emoji; `nil` leaves that part alone.
    @discardableResult
    public func edit(_ convoID: String, label: String?, emoji: String?) async -> String? {
        let label = label.map(ConvoPin.clampLabel)
        if let label, label.isEmpty { return "A pin needs a name." }
        return await write { try await $0.setPin(convoID, label: label, emoji: emoji.map(ConvoPin.clampEmoji)) }
    }

    @discardableResult
    public func unpin(_ convoID: String) async -> String? {
        await write { try await $0.unpin(convoID) }
    }

    /// Re-points the pin on `convoID` at `to` (Move pin…, or the successor
    /// hint's "Move pin here").
    @discardableResult
    public func move(_ convoID: String, to: String) async -> String? {
        await write { try await $0.movePin(convoID, to: to) }
    }

    /// Hides the pin's current successor hint.
    @discardableResult
    public func dismissSuccessor(of convoID: String) async -> String? {
        guard let successor = pin(for: convoID)?.successor else { return nil }
        return await write { try await $0.dismissPinSuccessor(convoID, successorID: successor.convoID) }
    }

    /// The whole new order. Shown at once; a refusal puts the old one back.
    @discardableResult
    public func reorder(_ order: [String]) async -> String? {
        let before = pins
        let byID = Dictionary(uniqueKeysWithValues: pins.map { ($0.convoID, $0) })
        let reordered = order.compactMap { byID[$0] }
        guard reordered.count == pins.count else { return nil }
        pins = reordered
        let error = await write { try await $0.reorderPins(order) }
        if error != nil, pins == reordered { pins = before }
        return error
    }

    /// Moves one pin a step up or down.
    @discardableResult
    public func moveStep(_ convoID: String, up: Bool) async -> String? {
        guard let order = ConvoPin.movedOrder(pins, convoID, up: up) else { return nil }
        return await reorder(order)
    }

    /// The label a conversation's title suggests: the `[ab] ` session short
    /// (and a room's 🔗) peeled off, clamped to the journal's rule.
    public nonisolated static func suggestedLabel(fromTitle title: String) -> String {
        let clean = SessionTag.splitTitle(title.trimmingCharacters(in: .whitespacesAndNewlines)).title
        let label = ConvoPin.clampLabel(clean)
        return label.isEmpty ? ConvoPin.labelFallback : label
    }

    // MARK: - Internals

    private func write(_ call: (any PinsProviding) async throws -> ConvoPinList) async -> String? {
        do {
            let answer = try await call(api)
            isSupported = true
            errorMessage = nil
            adopt(answer)
            return nil
        } catch {
            let message = Self.message(for: error)
            errorMessage = message
            Self.logger.warning("pins write failed: \(error.localizedDescription, privacy: .public)")
            return message
        }
    }

    static func message(for error: Error) -> String {
        if let pinError = error as? ConvoPinError { return pinError.localizedDescription }
        return "Couldn't update pins — \(error.localizedDescription)"
    }

    private func applyLive(_ pins: [ConvoPin]) {
        epoch += 1
        isSupported = true
        if self.pins != pins { self.pins = pins }
    }

    private func adopt(_ answer: ConvoPinList) {
        epoch += 1
        limit = answer.limit
        if pins != answer.pins { pins = answer.pins }
    }
}
