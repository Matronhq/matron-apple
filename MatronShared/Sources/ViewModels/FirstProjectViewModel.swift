import Foundation
import Observation
import CryptoKit
import MatronJournal
import MatronModels

public enum FirstProjectKind: String, Codable, CaseIterable, Identifiable {
    case design, app, research, report, own
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .design: "Explore design directions"
        case .app: "Build a fitness tracker"
        case .research: "Research a market"
        case .report: "Make a report"
        case .own: "My own idea"
        }
    }
    public var example: String {
        switch self {
        case .design: "Make three visual directions for a fitness tracker: calm, bold and playful."
        case .app: "Build a simple fitness tracker that saves workouts on this device and shows weekly totals."
        case .research: "Research the market for simple fitness trackers. Compare five products, with sources and dates."
        case .report: "Make a short report from this sample: Monday 30 minutes, Tuesday 20, Thursday 45, Friday 25, Sunday 40."
        case .own: ""
        }
    }
}

/// No authorization URL, returned code or provider credential is persisted.
public struct FirstProjectProgress: Codable, Equatable {
    public var dismissed = false
    public var completed = false
    public var boxID: Int64?
    public var flowID: String?
    public var kind: FirstProjectKind = .design
    public var brief = FirstProjectKind.design.example
    public var startUnconfirmed = false
    public var conversationID: String?
    public var messageID = UUID().uuidString
    public var promptQueued = false
    public init() {}

    public static func defaultsKey(server: URL, userID: String) -> String {
        let account = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "\n" + userID
        return "firstProject.v1." + SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct FirstProjectResult {
    public static let noticeTitle = "Your first project is ready"
    public let noticeID: String
    public let title: String
    public let projectID: String?
    public init(noticeID: String, title: String, projectID: String? = nil) {
        self.noticeID = noticeID; self.title = title; self.projectID = projectID
    }
}

@Observable @MainActor
public final class FirstProjectViewModel {
    public private(set) var progress: FirstProjectProgress
    public private(set) var boxes: [DeviceDTO] = []
    public private(set) var connection = "unknown"
    public private(set) var authorizationURL: URL?
    public private(set) var result: FirstProjectResult?
    public private(set) var busy = false
    public private(set) var errorMessage: String?
    public var approvalSigner: ApprovalSigner?
    private let api: any AgentRPCProviding
    private let save: (FirstProjectProgress) -> Void
    private let send: (String, String, String) async throws -> Void
    private let readResult: (String) async throws -> FirstProjectResult?

    public init(api: any AgentRPCProviding, progress: FirstProjectProgress = .init(),
                save: @escaping (FirstProjectProgress) -> Void,
                send: @escaping (String, String, String) async throws -> Void,
                readResult: @escaping (String) async throws -> FirstProjectResult?) {
        self.api = api; self.progress = progress; self.save = save
        self.send = send; self.readResult = readResult
    }

    public var step: Int { progress.conversationID != nil || progress.startUnconfirmed ? 3 : connection == "connected" ? 2 : 1 }
    public var selectedBox: DeviceDTO? { boxes.first { $0.id == progress.boxID } }
    public var needsRefresh: Bool {
        progress.conversationID != nil && result == nil || ["starting", "waiting", "checking"].contains(connection)
    }
    public var canStart: Bool {
        connection == "connected" && selectedBox?.connected == true
        && progress.conversationID == nil && !progress.startUnconfirmed
        && !progress.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !busy
    }

    public func choose(_ kind: FirstProjectKind) {
        guard !busy, step == 2 else { return }
        progress.kind = kind; progress.brief = kind.example; persist()
    }
    public func setBrief(_ brief: String) { progress.brief = String(brief.prefix(1600)); persist() }
    public func skip() { progress.dismissed = true; persist() }
    public func openedResult() { guard result != nil else { return }; progress.completed = true; persist() }
    private func persist() { save(progress) }

    public func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        errorMessage = nil
        do {
            try await loadBoxes()
            if selectedBox == nil {
                progress.boxID = boxes.first?.id
                progress.flowID = nil
                persist()
            }
            if progress.conversationID != nil {
                try await queueBriefIfNeeded()
                try await refreshResult()
            } else if progress.boxID != nil {
                try await updateConnection(action: "status")
            }
        } catch {
            errorMessage = progress.conversationID != nil && !progress.promptQueued
                ? briefSendFailure
                : "Couldn't reach your server. Check your connection and try again."
        }
    }

    public func selectBox(_ id: Int64) async {
        guard !busy, progress.conversationID == nil, !progress.startUnconfirmed else { return }
        busy = true
        defer { busy = false }
        errorMessage = nil
        // Cancel only this device's own pending login before switching.
        if let old = progress.boxID, let flow = progress.flowID {
            _ = try? await rpc(old, "claude_setup", ["action": "cancel", "flow_id": flow])
        }
        progress.boxID = id; progress.flowID = nil
        connection = "unknown"; authorizationURL = nil; persist()
        do { try await updateConnection(action: "status") }
        catch { errorMessage = "Couldn't reach this server. Try again when it is online." }
    }

    public func connect() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        errorMessage = nil
        do { try await updateConnection(action: "start") }
        catch { errorMessage = "Couldn't start Claude sign-in. Check your connection and try again." }
    }

    public func submit(code: String) async {
        guard !busy, let box = progress.boxID, let flow = progress.flowID else { return }
        busy = true
        defer { busy = false }
        errorMessage = nil
        do { adopt(try await rpc(box, "claude_setup", ["action": "submit", "flow_id": flow, "code": code])) }
        catch { errorMessage = "Couldn't send the sign-in code. Check the connection before trying again." }
    }

    public func cancelLogin() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        errorMessage = nil
        do { try await updateConnection(action: "cancel") }
        catch { errorMessage = "Couldn't cancel this sign-in. It will expire automatically." }
    }

    public func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if progress.conversationID != nil { try await refreshResult() }
            else {
                try await loadBoxes()
                try await updateConnection(action: "status")
            }
        } catch { errorMessage = "Couldn't check progress. You can try again or return later." }
    }

    public func startProject() async {
        guard canStart, let box = selectedBox else { return }
        busy = true
        defer { busy = false }
        errorMessage = nil
        var params: [String: Any] = ["agent": "claude"]
        do {
            if box.isProtected {
                guard let approvalSigner else { throw JournalAPIError.approvalRequired }
                let request = ApprovalRequest(kind: .account,
                    subject: ApprovalSubjects.start(box: box.name, workdir: nil, prompt: nil),
                    headline: "Start your first project on \(box.name)", box: box.name)
                guard let approval = try await approvalSigner(request) else { return }
                params["approval"] = approval.json
            }
            guard !Task.isCancelled else { return }
            // Save before a non-idempotent start. If its answer is lost, a
            // relaunch must not silently create another paid session.
            progress.startUnconfirmed = true; persist()
            let reply = try await api.agentRequest(agentDeviceID: box.id, method: "start",
                paramsData: JSONSerialization.data(withJSONObject: params))
            switch reply {
            case .failure(let code, _):
                progress.startUnconfirmed = false; persist()
                throw SetupFailure(code: code)
            case .ok(let data):
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let id = object?["convo_id"] as? String, !id.isEmpty else { throw RPCRequestError.timeout }
                progress.conversationID = id; progress.startUnconfirmed = false; persist()
                try await queueBriefIfNeeded()
            }
        } catch {
            if progress.conversationID != nil {
                errorMessage = briefSendFailure
            } else {
                errorMessage = progress.startUnconfirmed
                    ? "The server did not confirm the new chat. Check Conversations before starting again."
                    : "Couldn't start your project. Check your server and try again."
            }
        }
    }

    private var briefSendFailure: String {
        "Your chat is ready, but the brief could not be sent. Check your connection, then tap Send my brief."
    }

    /// Called only after the user confirms they checked Conversations.
    public func allowAnotherStart() { progress.startUnconfirmed = false; persist() }

    private func queueBriefIfNeeded() async throws {
        guard let id = progress.conversationID, !progress.promptQueued else { return }
        let prompt = """
        \(progress.brief)

        Make this a project and do the work. Use example data unless I provide my own, and include sources for research. When the finished result is ready, send me a notice called “\(FirstProjectResult.noticeTitle)” with a link or attachment I can open on my phone. Ask me if you need anything to proceed.
        """
        try await send(id, prompt, progress.messageID)
        progress.promptQueued = true; persist()
    }

    private func refreshResult() async throws {
        guard let id = progress.conversationID else { return }
        result = try await readResult(id)
        errorMessage = nil
    }

    private func loadBoxes() async throws {
        boxes = try await api.devices().filter { $0.kind == "agent" }
            .sorted { $0.connected != $1.connected ? $0.connected : $0.name < $1.name }
    }

    private func updateConnection(action: String) async throws {
        guard let box = progress.boxID else { return }
        guard selectedBox?.connected == true else {
            adopt(["state": "offline"])
            return
        }
        var params: [String: Any] = ["action": action]
        if let flow = progress.flowID { params["flow_id"] = flow }
        adopt(try await rpc(box, "claude_setup", params))
    }
    private func rpc(_ box: Int64, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        switch try await api.agentRequest(agentDeviceID: box, method: method, paramsData: JSONSerialization.data(withJSONObject: params)) {
        case .ok(let data):
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SetupFailure(code: "bad_response") }
            return object
        case .failure(let code, _):
            // These replies prove the server is reachable. Let the normal
            // state UI explain the remedy instead of showing a network error.
            if code == "unknown_method" { return ["state": "unsupported"] }
            if code == "box_locked" { return ["state": "locked"] }
            if code == "agent_unreachable" { return ["state": "offline"] }
            throw SetupFailure(code: code)
        }
    }
    private func adopt(_ object: [String: Any]) {
        errorMessage = nil
        connection = object["state"] as? String ?? "unavailable"
        authorizationURL = nil
        if let string = object["authorization_url"] as? String, let url = URL(string: string),
           url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
           (url.host == "claude.ai" && url.path == "/oauth/authorize"
            || url.host == "claude.com" && url.path == "/cai/oauth/authorize") { authorizationURL = url }
        if let flow = object["flow_id"] as? String { progress.flowID = flow }
        if connection == "connected" { progress.flowID = nil }
        if connection == "invalid_code" { errorMessage = "That code was not accepted. Copy the full code from Claude and try again." }
        persist()
    }
    private struct SetupFailure: Error { let code: String }
}
