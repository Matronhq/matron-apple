import Foundation
import SwiftUI
import os
import MatronEvents

/// State machine + socket client behind one `LiveOutputCard`. Connects to
/// the bridge's viewer WebSocket (`…/live/ws?token=…`), accumulates
/// ANSI-rendered output, and tracks the command's lifecycle. One instance
/// per `tool_use_id`, owned by `LiveOutputSessionStore` so a row that
/// scrolls out of the LazyVStack and back reuses the same accumulated
/// output and connection instead of replaying from scratch.
///
/// Reconnect semantics: the viewer replays the whole log from offset 0 on
/// every connect. `consumedBytes` counts what we've already rendered, and
/// each (re)connect skips that prefix — matron-web's byte-offset
/// accounting, minus its IndexedDB layer (the server replay IS our cache).
@MainActor
@Observable
public final class LiveOutputSession {
    public enum Phase: Equatable, Sendable {
        case idle
        case connecting
        case streaming
        case complete(exitCode: Int?, denied: Bool, truncated: Bool)
        case expired
        /// Socket failed / closed abnormally and retries are exhausted.
        case disconnected
    }

    public private(set) var phase: Phase = .idle
    public private(set) var output = AttributedString()
    public private(set) var hasOutput = false

    public let event: LiveOutputEvent

    /// Frame-stream factory, injectable for tests. The default connects a
    /// `URLSessionWebSocketTask` and yields decoded frames until close.
    public typealias Connector = @Sendable (URL) -> AsyncThrowingStream<LiveOutputFrame, Error>

    private let connector: Connector
    private var parser = AnsiSGRParser()
    private var consumedBytes = 0
    private var runTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var attempts = 0
    private static let maxAttempts = 3
    private static let logger = os.Logger(subsystem: "chat.matron", category: "live-output")

    public init(event: LiveOutputEvent, connector: Connector? = nil) {
        self.event = event
        self.connector = connector ?? Self.webSocketConnector
    }

    /// Idempotent kick-off — call from the card's `.task`/`onAppear`.
    public func startIfNeeded() {
        guard runTask == nil else { return }
        if case .complete = phase { return }
        guard let socketURL = event.socketURL else {
            phase = .disconnected
            return
        }
        if event.isExpired {
            phase = .expired
            return
        }
        scheduleExpiry()
        runTask = Task { [weak self] in
            await self?.run(socketURL: socketURL)
        }
    }

    /// Terminal states stop the loop; anything else means "try again"
    /// until the retry budget runs out.
    private var isTerminal: Bool {
        switch phase {
        case .complete, .expired: return true
        case .idle, .connecting, .streaming, .disconnected: return false
        }
    }

    private func run(socketURL: URL) async {
        defer { runTask = nil }
        while !Task.isCancelled && !isTerminal && attempts < Self.maxAttempts {
            attempts += 1
            phase = .connecting
            // Each connect replays from offset 0 — skip what's rendered.
            var replayOffset = 0
            do {
                for try await frame in connector(socketURL) {
                    if Task.isCancelled { return }
                    switch frame {
                    case .data(let chunk):
                        if phase != .streaming { phase = .streaming }
                        let size = chunk.utf8.count
                        if replayOffset + size <= consumedBytes {
                            replayOffset += size
                            continue // fully within the already-rendered prefix
                        }
                        var fresh = chunk
                        if replayOffset < consumedBytes {
                            // Frame straddles the replay boundary — drop the
                            // rendered prefix. Byte-slicing UTF-8 is safe here
                            // because the boundary was itself a frame edge in
                            // the previous connection.
                            let skip = consumedBytes - replayOffset
                            fresh = String(decoding: Array(chunk.utf8.dropFirst(skip)), as: UTF8.self)
                        }
                        replayOffset += size
                        consumedBytes = max(consumedBytes, replayOffset)
                        let rendered = parser.append(fresh)
                        if !rendered.characters.isEmpty {
                            output += rendered
                            hasOutput = true
                        }
                    case .complete(let exitCode, let denied, let truncated):
                        phase = .complete(exitCode: exitCode, denied: denied, truncated: truncated)
                        expiryTask?.cancel()
                        return
                    }
                }
                // Clean close without a `complete` frame (e.g. token just
                // expired server-side, or the log was GC'd).
                if !isTerminal {
                    phase = event.isExpired ? .expired : .disconnected
                }
            } catch {
                Self.logger.debug("viewer socket error (attempt \(self.attempts)): \(error.localizedDescription, privacy: .public)")
                if event.isExpired {
                    phase = .expired
                    return
                }
                phase = .disconnected
                if attempts < Self.maxAttempts {
                    try? await Task.sleep(for: .seconds(Double(attempts) * 2))
                }
            }
        }
    }

    /// Force-closes at `expires_at` so a still-streaming pane doesn't sit
    /// in `.streaming` on a socket the server is about to reject anyway.
    private func scheduleExpiry() {
        guard let expiresAt = event.expiresAt else { return }
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            let interval = expiresAt.timeIntervalSinceNow
            if interval > 0 {
                try? await Task.sleep(for: .seconds(interval))
            }
            guard let self, !Task.isCancelled else { return }
            if !self.isTerminal {
                self.runTask?.cancel()
                self.runTask = nil
                self.phase = .expired
            }
        }
    }

    public func teardown() {
        runTask?.cancel()
        runTask = nil
        expiryTask?.cancel()
        expiryTask = nil
    }

    /// Live `URLSessionWebSocketTask` connector (the default). Yields
    /// decoded frames; finishes on clean close, throws on failure.
    private static let webSocketConnector: Connector = { url in
        AsyncThrowingStream { continuation in
            let task = URLSession.shared.webSocketTask(with: url)
            task.resume()
            let pump = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let text: String?
                        switch message {
                        case .string(let s): text = s
                        case .data(let d): text = String(data: d, encoding: .utf8)
                        @unknown default: text = nil
                        }
                        if let text, let frame = LiveOutputFrame.decode(text) {
                            continuation.yield(frame)
                        }
                    }
                    continuation.finish()
                } catch {
                    // A normal close surfaces from receive() as an error on
                    // some OS versions — treat explicit 1000 as clean EOF.
                    if task.closeCode == .normalClosure {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}

/// Process-wide registry of live-output sessions keyed by `tool_use_id`.
/// LazyVStack recycles rows as the user scrolls; without this each
/// re-mount would open a fresh socket and replay the whole log. Bounded
/// LRU — a long chat full of command tiles keeps only the most recently
/// visible sessions' output in memory.
@MainActor
public final class LiveOutputSessionStore {
    public static let shared = LiveOutputSessionStore()

    private var sessions: [String: LiveOutputSession] = [:]
    private var order: [String] = []
    private let limit: Int

    public init(limit: Int = 8) {
        self.limit = limit
    }

    public func session(for event: LiveOutputEvent) -> LiveOutputSession {
        if let existing = sessions[event.toolUseID] {
            order.removeAll { $0 == event.toolUseID }
            order.append(event.toolUseID)
            return existing
        }
        let created = LiveOutputSession(event: event)
        sessions[event.toolUseID] = created
        order.append(event.toolUseID)
        if order.count > limit {
            let evicted = order.removeFirst()
            sessions.removeValue(forKey: evicted)?.teardown()
        }
        return created
    }
}
