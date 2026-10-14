import Foundation
import Observation
import MatronEvents
import MatronJournal
import MatronModels

/// Backs Settings ▸ Coordinator ▸ Routines: the user's Coordinator routines,
/// sorted by name, with pause/resume, run now, create, edit and delete.
///
/// Like `MemoriesViewModel`: nothing is cached locally and nothing loads
/// until the screen calls `start()`, so a journal that predates `/routines`
/// answers its 404 on this screen alone (as `isSupported == false`).
///
/// Live: while started, every `routine` marker (create, edit, delete,
/// fire — the journal appends one into the Coordinator conversation)
/// schedules one refetch after a short delay, so a burst costs a single
/// `GET /routines`.
@MainActor @Observable
public final class RoutinesViewModel {
    /// Sorted by name. `nil` until the first load lands.
    public private(set) var routines: [Routine]?
    /// `false` once the journal has 404'd `GET /routines`; `nil` until the
    /// first answer; `true` once a load has succeeded.
    public private(set) var isSupported: Bool?
    public private(set) var isLoading = false
    /// The last load's failure. Loads never clear `routines` on failure.
    public private(set) var loadError: String?
    /// The last list action's failure or note (pause, run now), shown once.
    public var actionMessage: String?
    /// Routines with a pause/resume or run request in flight.
    public private(set) var busyIDs: Set<String> = []

    private let api: any RoutinesProviding
    private let markers: @Sendable () -> AsyncStream<RoutineMarkerEvent>
    private let refetchDelay: Duration
    private var markerTask: Task<Void, Never>?
    private var refetchTask: Task<Void, Never>?
    /// Bumped by every load: an older answer that lands after a newer load
    /// started must never overwrite it.
    private var loadGeneration = 0

    public init(api: any RoutinesProviding,
                markers: @escaping @Sendable () -> AsyncStream<RoutineMarkerEvent>,
                refetchDelay: Duration = .milliseconds(250)) {
        self.api = api; self.markers = markers; self.refetchDelay = refetchDelay
    }

    public var isStarted: Bool { markerTask != nil }

    /// The screen appeared: follow markers (once) and load.
    public func start() {
        if markerTask == nil {
            let stream = markers()
            markerTask = Task { [weak self] in
                for await _ in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.scheduleRefetch()
                }
            }
        }
        Task { await load() }
    }

    /// The screen went away: stop following markers. The loaded list is
    /// kept, so coming back shows it at once while the reload runs.
    public func stop() {
        markerTask?.cancel(); markerTask = nil
        refetchTask?.cancel(); refetchTask = nil
    }

    private func scheduleRefetch() {
        guard refetchTask == nil else { return }
        let delay = refetchDelay
        refetchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.refetchTask = nil
            await self.load()
        }
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let fetched = try await api.listRoutines()
            guard generation == loadGeneration else { return }
            routines = Self.sorted(fetched)
            isSupported = true
            loadError = nil
        } catch RoutinesError.unsupported {
            guard generation == loadGeneration else { return }
            isSupported = false
            loadError = nil
        } catch {
            guard generation == loadGeneration else { return }
            loadError = error.localizedDescription
        }
    }

    /// The journal's order (`ORDER BY name`).
    static func sorted(_ routines: [Routine]) -> [Routine] {
        routines.sorted { $0.name < $1.name }
    }

    public func routine(id: String) -> Routine? {
        routines?.first { $0.id == id }
    }

    /// Puts one routine's fresh copy into the list at once, so the row
    /// shows the change before the marker's refetch lands.
    private func replace(_ routine: Routine) {
        routines = Self.sorted((routines ?? []).filter { $0.id != routine.id } + [routine])
        // Any load already in flight was asked before this write: its
        // answer may not have it.
        loadGeneration += 1
        isLoading = false
    }

    /// Pause (`false`) or resume (`true`).
    public func setEnabled(_ enabled: Bool, id: String) async {
        guard !busyIDs.contains(id) else { return }
        busyIDs.insert(id)
        defer { busyIDs.remove(id) }
        do {
            replace(try await api.setRoutineEnabled(id: id, enabled: enabled))
        } catch {
            actionMessage = error.localizedDescription
            if case RoutinesError.notFound = error { await load() }
        }
    }

    /// Fires the routine now. The outcome lands later as a `fired` marker,
    /// which refetches the list. Answers `nil` once the journal accepted
    /// it, otherwise what to tell the user (not sent, or the error).
    public func run(id: String) async -> String? {
        guard !busyIDs.contains(id) else { return nil }
        busyIDs.insert(id)
        defer { busyIDs.remove(id) }
        do {
            return try await api.runRoutine(id: id).message
        } catch {
            return error.localizedDescription
        }
    }

    static let notLoadedError = "Routines haven't loaded yet, so this name can't be checked. Try again in a moment."

    /// Why this form can't be saved, or `nil`: the journal's rules, plus a
    /// new routine's name must not already be in the list.
    public func formError(isNew: Bool, name: String, draft: RoutineDraft) -> String? {
        if let problem = RoutineRules.formError(name: name, title: draft.title, prompt: draft.prompt, tz: draft.tz,
                                                schedule: draft.schedule, trigger: draft.trigger) {
            return problem
        }
        if isNew, routines == nil {
            return isSupported == false ? RoutinesError.unsupported.localizedDescription : Self.notLoadedError
        }
        if isNew, routines?.contains(where: { $0.name == name }) == true {
            return "A routine named \"\(name)\" already exists. Open it from the list to change it."
        }
        if isNew, (routines?.count ?? 0) >= RoutineRules.maxRoutines {
            return RoutinesError.tooMany.localizedDescription
        }
        return nil
    }

    /// Creates (`existingID == nil`) or edits. `nil` on success, otherwise
    /// the message to show.
    public func save(existingID: String?, name: String, draft: RoutineDraft) async -> String? {
        let isNew = existingID == nil
        if isNew, routines == nil { await load() }
        if let problem = formError(isNew: isNew, name: name, draft: draft) { return problem }
        do {
            if let existingID {
                replace(try await api.updateRoutine(id: existingID, draft: draft))
            } else {
                replace(try await api.createRoutine(name: name, draft: draft))
            }
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    /// `nil` on success, otherwise the message to show. A routine already
    /// gone counts as deleted.
    public func delete(id: String) async -> String? {
        do {
            try await api.deleteRoutine(id: id)
        } catch RoutinesError.notFound {
            // Already gone: fall through and drop it here too.
        } catch {
            return error.localizedDescription
        }
        routines = routines?.filter { $0.id != id }
        loadGeneration += 1
        isLoading = false
        return nil
    }
}
