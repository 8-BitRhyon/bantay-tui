import Foundation
import Network

/// Control-gateway wire contract (W1, plan 017 WI-4): versioned NDJSON
/// request/response over a Unix domain socket. Unknown fields are ignored,
/// unknown methods rejected — the server enforces that server-side. The pure
/// framing/parsing/route helpers live here so the CLI harness can spec-check
/// them without a live socket.
enum ControlGateway {
    /// Method catalog verb for routing.
    enum GatewayMethod {
        case ping
        case list
        case read
        case sendKeys
        case focus
        case prompt
        case unknown
    }

    /// One NDJSON request envelope: `{"id":...,"method":...,"params":{...}}`.
    /// `[String: Any]` has no Decodable conformance, so `params` is bridged
    /// through a JSON box; a `params` value that is not a JSON object makes
    /// the whole decode fail (→ `parseRequest` returns nil).
    struct GatewayRequest: Decodable {
        let id: String
        let method: String
        let params: [String: Any]?

        enum CodingKeys: String, CodingKey {
            case id, method, params
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            method = try container.decode(String.self, forKey: .method)
            params = try container.decodeIfPresent(JSONObject.self, forKey: .params)?.value
        }
    }

    /// Response builders producing one NDJSON line each. Success carries
    /// `result` and a null `error`; errors carry a null `result` and a
    /// `{code,message}` object — the shape `HerdrSocketClient` already speaks.
    enum GatewayResponse {
        static func ok(id: String, result: [String: Any]) -> String {
            line(from: ["id": id, "result": result, "error": NSNull()])
        }

        static func error(id: String, code: String, message: String) -> String {
            line(from: [
                "id": id,
                "result": NSNull(),
                "error": ["code": code, "message": message],
            ])
        }

        private static func line(from object: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else {
                return "{}"
            }
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    /// Method catalog + membership check. Unknown methods are rejected with
    /// `unknown_method` before any adapter verb is touched.
    enum GatewayRoute {
        static let catalog: [String] = [
            "bantay.ping", "agent.list", "pane.read",
            "pane.send_keys", "pane.focus", "agent.prompt",
        ]

        static func isKnown(_ method: String) -> Bool {
            catalog.contains(method)
        }
    }

    /// Split an accumulated byte stream into complete NDJSON lines, dropping
    /// any single line larger than the 64 KiB cap (W1 adversarial rule:
    /// oversized lines close the connection at the server).
    static func extractLines(from data: Data) -> [String] {
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.utf8.count <= 64 * 1024 }
    }

    /// Parse one request line. Returns nil for non-JSON, a missing/non-string
    /// `id` or `method`, or a `params` value that is not a JSON object —
    /// the server closes such connections without a response.
    static func parseRequest(_ line: String) -> (
        id: String, method: String, params: [String: Any]?
    )? {
        guard let data = line.data(using: .utf8),
            let request = try? JSONDecoder().decode(GatewayRequest.self, from: data)
        else {
            return nil
        }
        return (request.id, request.method, request.params)
    }

    /// Pure mapping from a method name to its route verb.
    static func route(method: String) -> GatewayMethod {
        switch method {
        case "bantay.ping": return .ping
        case "agent.list": return .list
        case "pane.read": return .read
        case "pane.send_keys": return .sendKeys
        case "pane.focus": return .focus
        case "agent.prompt": return .prompt
        default: return .unknown
        }
    }

    /// Resolve the control socket path: `BANTAY_CONTROL_SOCKET` wins, else
    /// `~/Library/Application Support/Bantay-TUI/control.sock`.
    static func socketPath(env: [String: String], home: String) -> String {
        if let explicit = env["BANTAY_CONTROL_SOCKET"], !explicit.isEmpty {
            return explicit
        }
        return home + "/Library/Application Support/Bantay-TUI/control.sock"
    }

    static func socketPath() -> String {
        socketPath(env: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
    }

    /// `bantay.ping` kind: the active multiplexer family from pure detection,
    /// or `none` when no multiplexer drives the control plane.
    static func detectedKind(env: [String: String]) -> String {
        PlexerDetection.detect(env: env).map(\.rawValue) ?? "none"
    }

    /// Decodes a JSON object into `[String: Any]`.
    private struct JSONObject: Decodable {
        let value: [String: Any]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let dict = try container.decode([String: JSONValue].self)
            value = dict.mapValues(\.value)
        }
    }

    /// Recursive JSON value bridge. Numbers are decoded before booleans so a
    /// numeric param (`"lines": 6`) stays a number instead of collapsing to a
    /// Bool through JSONDecoder's NSNumber bridging.
    private struct JSONValue: Decodable {
        let value: Any

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                value = NSNull()
            } else if let number = try? container.decode(Double.self) {
                value = number
            } else if let bool = try? container.decode(Bool.self) {
                value = bool
            } else if let string = try? container.decode(String.self) {
                value = string
            } else if let array = try? container.decode([JSONValue].self) {
                value = array.map(\.value)
            } else if let object = try? container.decode([String: JSONValue].self) {
                value = object.mapValues(\.value)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "unsupported JSON value")
            }
        }
    }
}

/// Control gateway listener on a Unix domain socket (W1). One connection,
/// one request line, one response line, then close — the same request/response
/// model as `HerdrSocketClient.perform`. A stale socket file left by a crash
/// is probed and unlinked before binding; a live socket (second app instance)
/// is preserved so the bind fails rather than stealing the control plane.
final class ControlGatewayServer: @unchecked Sendable {
    private let socketPath: String
    private let adapter: any PlexerAdapter
    private var listener: NWListener?

    init(socketPath: String, adapter: any PlexerAdapter) {
        self.socketPath = socketPath
        self.adapter = adapter
    }

    func start() {
        Self.prepareSocket(at: socketPath)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        let listener = try? NWListener(using: parameters)
        self.listener = listener
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Self.accept(connection, server: self)
        }
        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Request handling

    private func handle(line: String) -> String? {
        guard let request = ControlGateway.parseRequest(line) else { return nil }
        switch ControlGateway.route(method: request.method) {
        case .ping:
            return ControlGateway.GatewayResponse.ok(
                id: request.id,
                result: [
                    "type": "pong",
                    "v": 1,
                    "kind": ControlGateway.detectedKind(
                        env: ProcessInfo.processInfo.environment),
                ])
        case .list:
            return handleList(id: request.id, params: request.params)
        case .read:
            return handleRead(id: request.id, params: request.params)
        case .sendKeys:
            return handleSendKeys(id: request.id, params: request.params)
        case .focus:
            return handleFocus(id: request.id, params: request.params)
        case .prompt:
            return handlePrompt(id: request.id, params: request.params)
        case .unknown:
            return ControlGateway.GatewayResponse.error(
                id: request.id, code: "unknown_method", message: request.method)
        }
    }

    private func handleList(id: String, params: [String: Any]?) -> String {
        let kind = ControlGateway.detectedKind(env: ProcessInfo.processInfo.environment)
        let agents: [[String: Any]] = adapter.listPanes().map { pane in
            var entry: [String: Any] = ["id": pane.id]
            if let title = pane.title { entry["title"] = title }
            if let cwd = pane.cwd { entry["cwd"] = cwd }
            if let workspaceId = pane.workspaceId { entry["workspace_id"] = workspaceId }
            return entry
        }
        return ControlGateway.GatewayResponse.ok(id: id, result: ["kind": kind, "agents": agents])
    }

    private func handleRead(id: String, params: [String: Any]?) -> String {
        guard let paneId = stringParam(params, "pane_id"), !paneId.isEmpty else {
            return invalidParams(id, method: "pane.read")
        }
        let lines = max(intParam(params, "lines", default: 6), 1)
        let text = captureTail(paneId: paneId, lines: lines)
        return ControlGateway.GatewayResponse.ok(id: id, result: ["text": text])
    }

    private func handleSendKeys(id: String, params: [String: Any]?) -> String {
        guard let paneId = stringParam(params, "pane_id"), !paneId.isEmpty,
            let keys = params?["keys"] as? [String], !keys.isEmpty
        else {
            return invalidParams(id, method: "pane.send_keys")
        }
        adapter.sendKeys(paneId: paneId, keys: keys)
        return ControlGateway.GatewayResponse.ok(id: id, result: ["ok": true])
    }

    private func handleFocus(id: String, params: [String: Any]?) -> String {
        guard let paneId = stringParam(params, "pane_id"), !paneId.isEmpty else {
            return invalidParams(id, method: "pane.focus")
        }
        adapter.focusPane(paneId: paneId)
        return ControlGateway.GatewayResponse.ok(id: id, result: ["ok": true])
    }

    private func handlePrompt(id: String, params: [String: Any]?) -> String {
        guard let paneId = stringParam(params, "pane_id"), !paneId.isEmpty,
            let text = stringParam(params, "text"), !text.isEmpty
        else {
            return invalidParams(id, method: "agent.prompt")
        }
        adapter.sendLine(paneId: paneId, text: text)
        return ControlGateway.GatewayResponse.ok(id: id, result: ["ok": true])
    }

    private func invalidParams(_ id: String, method: String) -> String {
        ControlGateway.GatewayResponse.error(
            id: id, code: "invalid_params", message: method)
    }

    private func stringParam(_ params: [String: Any]?, _ key: String) -> String? {
        params?[key] as? String
    }

    private func intParam(_ params: [String: Any]?, _ key: String, default defaultValue: Int)
        -> Int
    {
        if let value = params?[key] as? Int { return value }
        if let value = params?[key] as? Double { return Int(value) }
        if let value = params?[key] as? NSNumber { return value.intValue }
        return defaultValue
    }

    /// The adapter's `captureTail` is async; the responder is sync
    /// (one line in, one line out), so the call is awaited on a detached
    /// task with a bounded wait — the same seam `HerdrSocketAdapter.listPanes`
    /// uses for its sync protocol method.
    private func captureTail(paneId: String, lines: Int) -> String {
        final class Box: @unchecked Sendable {
            var text = ""
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let adapter = self.adapter
        Task.detached {
            box.text = await adapter.captureTail(paneId: paneId, lines: lines)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3.0)
        return box.text
    }

    // MARK: - Connection + stale-socket handling

    /// Unlink a stale socket file left by a crash. If a live server is
    /// already listening, the connect probe succeeds and the file is kept
    /// so a second app instance fails to bind instead of stealing the socket.
    static func prepareSocket(at path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if !isLiveSocket(at: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private static func isLiveSocket(at path: String) -> Bool {
        final class ProbeState: @unchecked Sendable {
            var live = false
        }
        let semaphore = DispatchSemaphore(value: 0)
        let state = ProbeState()
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        connection.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .ready:
                state.live = true
                semaphore.signal()
            case .failed:
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "bantay.control.probe"))
        _ = semaphore.wait(timeout: .now() + 0.5)
        connection.cancel()
        return state.live
    }

    private static func accept(_ connection: NWConnection, server: ControlGatewayServer) {
        // Request handling can block on subprocess verbs, so the connection
        // runs on its own queue rather than the main actor.
        connection.start(queue: DispatchQueue(label: "bantay.control.connection"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            data, _, isComplete, error in
            if error != nil && !isComplete {
                connection.cancel()
                return
            }
            guard let data, let line = ControlGateway.extractLines(from: data).first else {
                connection.cancel()
                return
            }
            guard let response = server.handle(line: line) else {
                connection.cancel()
                return
            }
            connection.send(
                content: Data((response + "\n").utf8),
                completion: .contentProcessed { _ in
                    connection.cancel()
                })
        }
    }
}
