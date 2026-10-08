import Foundation

/// Speaks the journal agent protocol to the local rig as mac-studio, so a UI
/// test can stream a reply into `perf-timeline` (`stream` ephemerals, then
/// `finalize`). Token from `RIG_AGENT_TOKEN`, passed to the runner as
/// `TEST_RUNNER_RIG_AGENT_TOKEN`.
final class RigAgent: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let token: String

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let token = environment["RIG_AGENT_TOKEN"], !token.isEmpty else { return nil }
        self.token = token
        task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:9810/ws")!)
    }

    func connect() async throws {
        task.resume()
        try await send(["op": "hello", "token": token, "cursor": NSNull()])
        while true {
            if case .string(let text) = try await task.receive(), text.contains("\"hello_ok\"") { return }
        }
    }

    func send(_ frame: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: frame)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func streamReply(convo: String, ref: String, chunks: [String], interval: UInt64 = 200_000_000) async throws {
        for chunk in chunks {
            try await send(["op": "stream", "convo_id": convo, "message_ref": ref, "text": chunk])
            try await Task.sleep(nanoseconds: interval)
        }
    }

    func finalize(convo: String, ref: String, body: String) async throws {
        try await send(["op": "finalize", "convo_id": convo, "message_ref": ref, "type": "text",
                        "payload": ["body": body, "message_ref": ref]])
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}
