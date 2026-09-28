import Foundation
import Observation
import MatronEvents
import MatronJournal
import MatronModels

/// Backs the Memories screen (spec 2026-09-27 memories, Apps): the user's
/// standing rules and facts, sorted by name, with save and delete.
///
/// Nothing is cached locally and nothing loads until the screen is shown:
/// `start()` is called by the screen, never by the shell, so a journal that
/// predates `/memories` answers its 404 on this screen alone (as
/// `isSupported == false`) and never puts an error anywhere else — the web
/// tracker's rule (matron-web PR #38).
///
/// Live: while started, every `memory` marker schedules one refetch after a
/// short delay. The journal appends one change to up to two conversations
/// (the writer's and the Coordinator's), so a burst costs a single
/// `GET /memories`.
@MainActor @Observable
public final class MemoriesViewModel {
    /// Sorted by name. `nil` until the first load lands (so an empty array
    /// really means "no memories", never "not loaded yet").
    public private(set) var memories: [Memory]?
    /// `false` once the journal has 404'd `GET /memories`; `nil` until the
    /// first answer; `true` once a load has succeeded.
    public private(set) var isSupported: Bool?
    public private(set) var isLoading = false
    /// The last load's failure. Loads never clear `memories` on failure, so
    /// with a list on screen this reads as "may be out of date".
    public private(set) var loadError: String?

    private let api: any MemoriesProviding
    private let markers: @Sendable () -> AsyncStream<MemoryMarkerEvent>
    private let refetchDelay: Duration
    private var markerTask: Task<Void, Never>?
    private var refetchTask: Task<Void, Never>?
    /// Bumped by every load: an older answer that lands after a newer load
    /// started must never overwrite it.
    private var loadGeneration = 0

    public init(api: any MemoriesProviding,
                markers: @escaping @Sendable () -> AsyncStream<MemoryMarkerEvent>,
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
        do {
            let fetched = try await api.listMemories()
            guard generation == loadGeneration else { return }
            memories = Self.sorted(fetched)
            isSupported = true
            loadError = nil
        } catch MemoriesError.unsupported {
            guard generation == loadGeneration else { return }
            isSupported = false
            loadError = nil
        } catch {
            guard generation == loadGeneration else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// The journal's order (`ORDER BY name`); names are ASCII, so a plain
    /// comparison agrees with SQLite's binary collation.
    static func sorted(_ memories: [Memory]) -> [Memory] {
        memories.sorted { $0.name < $1.name }
    }

    public func memory(named name: String) -> Memory? {
        memories?.first { $0.name == name }
    }

    /// Why this form can't be saved, or `nil`. The journal's own rules
    /// (`MemoryRules.formError`), plus one of the app's: a NEW memory must
    /// not take a name that is already in the list — `PUT` is an upsert,
    /// so it would silently replace that memory (an agent's, say).
    public func formError(isNew: Bool, name: String, description: String, body: String) -> String? {
        if let problem = MemoryRules.formError(name: name, description: description, body: body) { return problem }
        if isNew, memory(named: name) != nil {
            return "A memory named \"\(name)\" already exists. Open it from the list to change it."
        }
        return nil
    }

    /// Validates, then `PUT`s the whole memory. `nil` on success, otherwise
    /// the message to show. The saved memory goes into the list at once (so
    /// an editor that looks it up by name finds it even if the reload that
    /// follows fails), then the list is reloaded so the journal's copy —
    /// and any concurrent agent edit — wins.
    public func save(isNew: Bool, name: String, type: MemoryType, description: String, body: String) async -> String? {
        if let problem = formError(isNew: isNew, name: name, description: description, body: body) { return problem }
        do {
            let saved = try await api.saveMemory(name: name, description: MemoryRules.normalizedDescription(description),
                                                 body: body, type: type)
            memories = Self.sorted((memories ?? []).filter { $0.name != saved.name } + [saved])
        } catch {
            return error.localizedDescription
        }
        await load()
        return nil
    }

    /// `nil` on success, otherwise the message to show. A memory already
    /// gone (deleted on another device) counts as deleted.
    public func delete(name: String) async -> String? {
        do {
            try await api.deleteMemory(name: name)
        } catch MemoriesError.notFound {
            // Already gone: fall through and drop it here too.
        } catch {
            return error.localizedDescription
        }
        memories = memories?.filter { $0.name != name }
        await load()
        return nil
    }
}
