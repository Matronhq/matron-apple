import Foundation
import MatronJournal
@testable import MatronShare

/// Scriptable socket: `serve` queues a server frame, closing ends the
/// stream so a pending receive throws.
final class ShareFakeSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var closed = false
    private var sentFrames: [String] = []
    /// Called with each frame the client writes, after the hello.
    var onSend: (@Sendable (ShareFakeSocket, [String: Any]) -> Void)?

    var sent: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return sentFrames.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    func serve(_ object: [String: Any]) {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        lock.lock()
        if let waiter = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: text)
        } else {
            incoming.append(text)
            lock.unlock()
        }
    }

    func sendText(_ text: String) async throws {
        guard record(text) else { throw JournalConnectionError.socketClosed }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        if object["op"] as? String == "hello" {
            serve(["kind": "control", "op": "hello_ok", "seq": 10, "coordinator_convo_id": NSNull()])
        } else {
            onSend?(self, object)
        }
    }

    private func record(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        sentFrames.append(text)
        return true
    }

    func receiveText() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !incoming.isEmpty {
                let next = incoming.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: JournalConnectionError.socketClosed)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func ping() async throws {}

    func close() {
        lock.lock()
        closed = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(throwing: JournalConnectionError.socketClosed) }
    }

    /// Echoes a send back the way the journal fans it out.
    func echo(_ op: [String: Any], seq: Int64 = 11) {
        serve(["kind": "journal", "seq": seq, "convo_id": op["convo_id"] ?? "", "ts": 1_700_000_000_000,
               "sender": "user:someone", "type": op["type"] ?? "text", "payload": op["payload"] ?? [:]])
    }
}

struct ShareFakeConnector: WebSocketConnecting {
    let socket: ShareFakeSocket
    func connect(to url: URL) async throws -> any WebSocketConnection { socket }
}

/// Answers every HTTP request with one canned response.
final class ShareStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func session(status: Int = 200, json: [String: Any] = [:]) -> URLSession {
        Self.status = status
        Self.body = try! JSONSerialization.data(withJSONObject: json)
        Self.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShareStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Records what a sender asks of the network.
final class RecordingTransport: ShareTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _uploads: [String] = []
    private var _delivered: [[ClientOp]] = []
    private var uploadFailures: [String: Error] = [:]
    private var deliverFailures: [Error] = []

    var uploads: [String] { lock.lock(); defer { lock.unlock() }; return _uploads }
    var delivered: [[ClientOp]] { lock.lock(); defer { lock.unlock() }; return _delivered }

    func failUpload(of filename: String, with error: Error) {
        lock.lock(); uploadFailures[filename] = error; lock.unlock()
    }
    func failNextDelivery(with error: Error) {
        lock.lock(); deliverFailures.append(error); lock.unlock()
    }

    func upload(_ file: SharedFile, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try recordUpload(file.filename)
        progress(0.5)
        progress(1)
        return "blob-\(file.filename)"
    }

    private func recordUpload(_ filename: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let error = uploadFailures.removeValue(forKey: filename) { throw error }
        _uploads.append(filename)
    }

    func deliver(_ ops: [ClientOp]) async throws {
        try recordDelivery(ops)
    }

    private func recordDelivery(_ ops: [ClientOp]) throws {
        lock.lock()
        defer { lock.unlock() }
        _delivered.append(ops)
        if !deliverFailures.isEmpty { throw deliverFailures.removeFirst() }
    }
}

func makeSharedFile(_ name: String, mimeType: String = "application/zip", size: Int = 100) -> SharedFile {
    SharedFile(url: URL(fileURLWithPath: "/tmp/\(name)"), filename: name, mimeType: mimeType, sizeBytes: size)
}
