import Foundation
import MatronChat
import MatronJournal

/// The devices/pairing slice of `JournalAPI`, extracted so view models can
/// be tested against a fake without a URL session. `JournalAPI` conforms
/// as-is.
public protocol DevicesProviding: Sendable {
    /// The journal this API talks to — the signed-in account's server. A
    /// scanned pairing QR is only honoured when it names this origin.
    var serverURL: URL { get }
    func devices() async throws -> [DeviceDTO]
    func revokeDevice(id: Int64) async throws
    func renameDevice(id: Int64, name: String) async throws -> DeviceDTO
    func setDeviceTag(id: Int64, tagChar: String?) async throws
    func pairPreview(code: String) async throws -> PairPreview
    func pairApprove(code: String, agentName: String, tagChar: String?) async throws
    /// `PUT /devices/:id/defaults` for the picked keys; see `JournalAPI`.
    func setBoxDefaults(deviceID: Int64, _ picks: [BoxDefaults.Pick]) async throws -> BoxDefaults
}

public extension DevicesProviding {
    /// For fakes that never edit box defaults: what a journal predating
    /// them answers.
    func setBoxDefaults(deviceID: Int64, _ picks: [BoxDefaults.Pick]) async throws -> BoxDefaults {
        throw JournalAPIError.notFound
    }
}

extension JournalAPI: DevicesProviding {}

/// Devices-screen state: the signed-in user's device roster with
/// per-device revoke. Pull-based per the server spec — callers `refresh()`
/// on screen enter and the model re-fetches after every mutation; there is
/// no push signal for roster changes in v1. The one live part is each agent
/// box's defaults for new sessions (`box_defaults` frames, while
/// `listenForBoxDefaults()` runs).
@Observable @MainActor
public final class DevicesViewModel {
    /// Sorted for display: clients first, then agents, each newest-first.
    public private(set) var devices: [DeviceDTO] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// `false` once `PUT /devices/:id/defaults` has 404ed — a journal
    /// without box defaults — so the editor hides for the rest of the visit.
    public private(set) var boxDefaultsSupported = true

    private let api: any DevicesProviding
    /// Live `box_defaults` frames; nil where there is no sync engine
    /// (previews, tests that don't need them).
    private let boxDefaultsUpdates: (@Sendable () -> AsyncStream<BoxDefaultsUpdate>)?
    /// Fired after a successful self-revocation (server treats it as a
    /// logout — the token is already dead). The host app drops local
    /// credentials and returns to sign-in.
    private let onSelfRevoked: () -> Void
    /// The save in progress per box — one at a time; see `setBoxDefault`.
    private var boxSaves: [Int64: BoxSave] = [:]

    public init(api: any DevicesProviding,
                boxDefaultsUpdates: (@Sendable () -> AsyncStream<BoxDefaultsUpdate>)? = nil,
                onSelfRevoked: @escaping () -> Void) {
        self.api = api
        self.boxDefaultsUpdates = boxDefaultsUpdates
        self.onSelfRevoked = onSelfRevoked
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            devices = Self.sorted(try await api.devices())
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load devices — \(Self.describe(error))"
        }
    }

    /// Revokes `device`. 404 means it was already revoked elsewhere —
    /// treated as success. Self-revocation fires `onSelfRevoked` instead of
    /// re-fetching (the roster call would just 401 on the dead token).
    public func revoke(_ device: DeviceDTO) async {
        do {
            do {
                try await api.revokeDevice(id: device.id)
            } catch JournalAPIError.notFound {
                // Already gone — fall through to the success path.
            }
            if device.isSelf {
                onSelfRevoked()
            } else {
                // The server has already dropped the device — reflect that
                // locally first, because a failed refetch leaves `devices`
                // untouched and the dead row would linger.
                devices.removeAll { $0.id == device.id }
                await refresh()
            }
        } catch {
            errorMessage = "Couldn't revoke \(device.name) — \(Self.describe(error))"
        }
    }

    /// Server-side cap on a device name, mirrored here so the field can
    /// refuse before a round-trip.
    public static let nameCap = 40

    /// Name rules, mirrored from the server: non-empty after trimming, at
    /// most `nameCap` characters. Returns nil when acceptable, else the
    /// reason to show.
    public static func validate(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Give the device a name." }
        if trimmed.count > Self.nameCap { return "Names are at most \(Self.nameCap) characters." }
        return nil
    }

    /// Renames `device`. The roster is re-fetched on success rather than
    /// patched, so a name the server sanitised (control characters
    /// flattened) is what the user ends up seeing.
    public func rename(_ device: DeviceDTO, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.validate(name: trimmed) {
            errorMessage = problem
            return
        }
        do {
            _ = try await api.renameDevice(id: device.id, name: trimmed)
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = "Couldn't rename \(device.name) — \(Self.describe(error))"
        }
    }

    /// The client-side mirror of the server's tag sieve: trim, then keep
    /// only the first grapheme. Empty means "clear back to automatic",
    /// which the API expresses as nil. Two extra bounds match the server:
    /// a Character is a grapheme cluster, not one code point, so a Zalgo
    /// combining stack or a ZWJ chain over 16 scalars sieves to nil; and a
    /// cluster of only format/control/space scalars (soft hyphen, RLO) is
    /// a non-nil tag that renders as NOTHING — it would suppress the
    /// derived letter on every device with no visible explanation, so it
    /// sieves to nil too. The server enforces the same bounds; mirroring
    /// them here keeps the drafted value honest before it is sent.
    public static func tagChar(fromDraft draft: String) -> String? {
        guard let first = draft.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        let tag = String(first)
        guard tag.unicodeScalars.count <= 16 else { return nil }
        let visible = tag.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .format, .control, .spaceSeparator: return false
            default: return true
            }
        }
        return visible ? tag : nil
    }

    /// Sets or clears `device`'s roster tag character — journal-held, so
    /// the letter changes on every one of the user's devices at once.
    /// Re-fetches like `rename` so the row shows what the server stored.
    public func setTag(_ device: DeviceDTO, toDraft draft: String) async {
        do {
            try await api.setDeviceTag(id: device.id, tagChar: Self.tagChar(fromDraft: draft))
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = "Couldn't set the tag for \(device.name) — \(Self.describe(error))"
        }
    }

    // MARK: Box defaults (journal "Box defaults")

    /// Whether `device` gets the New sessions editor: an agent box the
    /// journal reported defaults for (an older journal sends none), on a
    /// journal that has not 404ed the route.
    public func showsBoxDefaults(for device: DeviceDTO) -> Bool {
        boxDefaultsSupported && device.kind == "agent" && device.defaults != nil
    }

    /// Picks `value` (nil = Box default) for one of `device`'s defaults:
    /// shown at once — a new agent clears the model, as the journal does —
    /// then saved. One save at a time per box: a pick made while one is on
    /// the wire waits, coalesced with any others, for the next `PUT`, so an
    /// agent change and the model picked right after it can't race (the
    /// journal's "new agent clears the model" would wipe the model). Each
    /// answer becomes the box's confirmed state, with the still-queued picks
    /// shown on top; a refusal puts back the confirmed state (plus the
    /// queue) and says why. Live frames for the box are held back while the
    /// save runs — one may be the echo of our own earlier `PUT`, landing
    /// after the follow-up left — so the answer to the newest request wins;
    /// a refusal falls back to the latest held frame. A 404 hides the
    /// editor and drops the queue. Returns at once when a save for the box
    /// is already running (it sends this pick next); otherwise once the
    /// queue is empty. Port of matron-android's `DevicesViewModel`.
    public func setBoxDefault(_ key: BoxDefaults.Key, to value: String?, for device: DeviceDTO) async {
        guard let shown = devices.first(where: { $0.id == device.id })?.defaults else { return }
        let picked = shown.applying(key, value)
        guard picked != shown else { return }
        let save = boxSaves[device.id] ?? BoxSave(confirmed: shown)
        boxSaves[device.id] = save
        save.queue(BoxDefaults.Pick(key, value))
        setDefaults(picked, for: device.id)
        guard !save.inFlight else { return }
        save.inFlight = true
        defer {
            save.inFlight = false
            boxSaves[device.id] = nil
        }
        while !save.pending.isEmpty {
            let picks = save.pending
            save.pending.removeAll()
            do {
                let stored = try await api.setBoxDefaults(deviceID: device.id, picks)
                // The answer to our newest request: it already holds
                // whatever a frame held back meanwhile reported.
                save.confirmed = stored
                save.frameDuringSave = nil
                setDefaults(stored.applying(save.pending), for: device.id)
                errorMessage = nil
            } catch {
                // Nothing was written; the latest frame held back (another
                // device's change, or our own echo) is the newest journal
                // state we know.
                if let frame = save.frameDuringSave { save.confirmed = frame }
                save.frameDuringSave = nil
                if case JournalAPIError.notFound = error {
                    save.pending.removeAll()
                    boxDefaultsSupported = false
                    errorMessage = "This journal can't set defaults for \(device.name)."
                } else {
                    let what = picks.count == 1 ? "the default \(picks[0].key.errorName)" : "the defaults"
                    errorMessage = "Couldn't save \(what) for \(device.name) — \(Self.describeBoxDefaults(error))"
                }
                setDefaults(save.confirmed.applying(save.pending), for: device.id)
            }
        }
    }

    /// Applies live `box_defaults` frames until the stream ends or the
    /// calling task is cancelled — run it in the screen's `.task`. A frame
    /// is the box's full new state, this device's own echo included.
    public func listenForBoxDefaults() async {
        guard let boxDefaultsUpdates else { return }
        for await update in boxDefaultsUpdates() {
            guard !Task.isCancelled else { return }
            apply(update)
        }
    }

    /// A frame is the journal's state, shown as is — except while a save of
    /// ours runs on that box, when it is held back for `setBoxDefault`'s
    /// answer (which supersedes it) or its revert.
    func apply(_ update: BoxDefaultsUpdate) {
        if let save = boxSaves[update.deviceID] {
            save.frameDuringSave = update.defaults
            return
        }
        setDefaults(update.defaults, for: update.deviceID)
    }

    /// Patches one row; a box not on the roster (yet) is left to the next
    /// `refresh()`.
    private func setDefaults(_ defaults: BoxDefaults, for id: Int64) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].defaults = defaults
    }

    /// The journal's 400 codes in words; anything else as `describe`.
    private static func describeBoxDefaults(_ error: Error) -> String {
        if case JournalAPIError.http(400, let code) = error {
            switch code {
            case "bad_agent": return "the journal doesn't know that agent."
            case "bad_model": return "that isn't a model name the journal accepts."
            case "bad_effort": return "the journal doesn't know that effort level."
            case "not_agent_device": return "only agent boxes have defaults."
            default: break
            }
        }
        return describe(error)
    }

    static func sorted(_ devices: [DeviceDTO]) -> [DeviceDTO] {
        devices.sorted { a, b in
            let aClient = a.kind == "client", bClient = b.kind == "client"
            if aClient != bClient { return aClient }
            return a.createdAt > b.createdAt
        }
    }

    static func describe(_ error: Error) -> String {
        if case JournalAPIError.transport = error { return "check your connection and try again." }
        return "the server said no (\(error))."
    }
}

/// One box's save in progress: the journal's last known state for it, the
/// picks queued for the next `PUT` (in the order made), and the latest live
/// frame held back while it runs.
@MainActor
private final class BoxSave {
    var confirmed: BoxDefaults
    var inFlight = false
    /// Not shown while the save runs: it may be the echo of an earlier `PUT`
    /// of ours, older than the queued picks and the answer still to come.
    var frameDuringSave: BoxDefaults?
    var pending: [BoxDefaults.Pick] = []

    init(confirmed: BoxDefaults) {
        self.confirmed = confirmed
    }

    /// Queues `pick`, replacing an earlier pick of the same key in place. A
    /// new agent drops a queued model: it belonged to the old agent (one
    /// picked after this queues again and travels with the agent).
    func queue(_ pick: BoxDefaults.Pick) {
        if pick.key == .agent { pending.removeAll { $0.key == .model } }
        if let index = pending.firstIndex(where: { $0.key == pick.key }) {
            pending[index] = pick
        } else {
            pending.append(pick)
        }
    }
}

/// Display helpers shared by the Mac and iOS device rows.
extension DeviceDTO {
    public var isClient: Bool { kind == "client" }

    /// SF Symbol for the row icon: apps are laptops, agents are terminals.
    public var symbolName: String { isClient ? "laptopcomputer" : "terminal" }

    /// `lag` is the user's head seq minus this device's cursor.
    public var lagText: String {
        lag <= 0 ? "Up to date" : "\(lag) event\(lag == 1 ? "" : "s") behind"
    }

    /// Relative last-seen. `nil` = never connected (e.g. an agent enrolled
    /// but whose box hasn't come online) → "Never", per the spec.
    public func lastSeenText(now: Date = Date()) -> String {
        guard let lastSeenAt else { return "Never" }
        let date = Date(timeIntervalSince1970: TimeInterval(lastSeenAt) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

extension BoxLetterMigration {
    /// App-start entry point for the legacy push-up: a device-local letter
    /// dictionary from before tags were journal-held moves to the server
    /// once, then vanishes. Returns nil (no task at all) for the common
    /// case — an install with no legacy overrides — so every later launch
    /// costs one UserDefaults read. Failures leave entries in place; the
    /// next launch retries.
    ///
    /// `userID` is the signed-in account. The legacy dictionary predates
    /// accounts and device ids repeat across journals, so the entries are
    /// bound to the first account that runs this (`BoxLetterOverrides.claim`)
    /// and every other account on the install returns nil here — nothing
    /// seeded into its mirror, nothing pushed to its boxes, nothing dropped.
    public static func runIfNeeded(
        api: any DevicesProviding,
        store: JournalStore,
        userID: String,
        defaults: UserDefaults = .standard
    ) -> Task<Void, Never>? {
        let legacy = BoxLetterOverrides.all(from: defaults)
        guard !legacy.isEmpty, BoxLetterOverrides.claim(userID: userID, in: defaults) else { return nil }
        return Task(priority: .utility) {
            // Seed the local mirror BEFORE any network round-trip — the
            // chat list paints letters from the store alone, so without
            // this an upgraded install reverts to derived letters until
            // the push lands, and forever against a journal that predates
            // `POST /devices/:id/tag` (the push 404s; only the relic
            // remains). Untagged rows only — a journal-held tag is newer
            // by construction — and `replaceAgents` carries the seed
            // across pre-tag snapshots (`tagCharKnown`).
            try? store.seedAgentTagChars(legacy)
            // The roster read is the freshness guard: a box that already
            // has a journal-held tag keeps it (the journal value is newer
            // by construction — this migration only runs while the local
            // relic exists). Unreachable server → retry next launch.
            guard let devices = try? await api.devices() else { return }
            let serverTags = Dictionary(uniqueKeysWithValues:
                devices.filter { $0.kind == "agent" }.map { ($0.id, $0.tagChar) })
            await run(defaults: defaults, serverTags: serverTags) { id, letter in
                try await api.setDeviceTag(id: id, tagChar: letter)
            }
        }
    }
}
