import Foundation
import Network

/// A parsed pane record from the herdr push event stream, carrying the same
/// fields `agent.list` returns so the roster can be rebuilt from events alone.
struct HerdrStreamPane: Equatable, Sendable {
    let paneId: String
    let agent: String?
    let agentStatus: String?
    let cwd: String?
    let workspaceId: String?
    let terminalTitle: String?
    let focused: Bool
}

/// Persistent push-event subscription to the herdr socket. Replaces the
/// 2-second `agent.list` poll for status transitions: `pane.updated` events
/// carry the full pane record (agent, status, cwd, title), so the roster can
/// stay live with sub-millisecond latency and zero polling processes.
///
/// Lifecycle: `start` opens the socket, sends `events.subscribe`, and drains
/// NDJSON lines forever. On transport failure it backs off and reconnects.
/// `stop` cancels everything. Parsed events are delivered on the main actor.
@MainActor
final class HerdrEventStream {
    enum StreamEvent {
        /// A pane was created or its record changed.
        case paneUpdated(HerdrStreamPane)
        /// A pane was closed/exited.
        case paneClosed(paneId: String)
        /// An agent was detected or released on a pane.
        case agentDetected(paneId: String, agent: String?, status: String?)
        /// The connection dropped; the caller should do a full snapshot.
        case disconnected
    }

    private var connection: NWConnection?
    private var task: Task<Void, Never>?
    private var buffer = Data()
    private var isSubscribed = false
    private var reconnectAttempt = 0
    private var stopped = false

    var onEvent: ((StreamEvent) -> Void)?

    private static let subscriptions: [String] = [
        "pane.updated", "pane.created", "pane.closed", "pane.agent_detected",
        "workspace.updated", "tab.focused",
    ]

    func start() {
        guard task == nil else { return }
        stopped = false
        task = Task { [weak self] in
            while !Task.isCancelled, !(self?.stopped ?? true) {
                guard let self else { return }
                await self.runConnection()
                if Task.isCancelled || self.stopped { break }
                // Back off between reconnects: 0.5s → 1s → 2s → 4s (cap).
                let delay = min(pow(2.0, Double(self.reconnectAttempt)), 4.0)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stop() {
        stopped = true
        task?.cancel()
        task = nil
        connection?.cancel()
        connection = nil
        isSubscribed = false
        buffer.removeAll()
    }

    private func runConnection() async {
        let path = HerdrSocketProtocol.socketPath(
            env: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
        guard FileManager.default.fileExists(atPath: path) else {
            // herdr is absent: back off so a herdr-less launch doesn't spin a
            // 1s probe forever. The reconnect backoff in `start` uses this
            // counter, so advance it here (0.5s → 1s → 2s → 4s cap).
            reconnectAttempt += 1
            return
        }
        let connection = NWConnection(
            to: .unix(path: path), using: .tcp)
        self.connection = connection

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let settle = SendableFlag()
            // Assign the handler BEFORE start so the `.ready` callback is not
            // missed (NWConnection fires state updates once started).
            connection.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        let sub = HerdrSocketProtocol.requestLine(
                            id: "bantay_sub",
                            method: "events.subscribe",
                            paramsJSON: Self.subscribeParamsJSON())
                        connection.send(
                            content: Data((sub + "\n").utf8),
                            completion: .contentProcessed { _ in })
                        self.isSubscribed = true
                        self.reconnectAttempt = 0
                        self.receiveLoop(connection)
                        if settle.markOnce() { continuation.resume() }
                    case .failed, .cancelled:
                        self.connection = nil
                        self.isSubscribed = false
                        self.onEvent?(.disconnected)
                        if settle.markOnce() { continuation.resume() }
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .main)
        }
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            MainActor.assumeIsolated {
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drainLines()
                }
                if isComplete || error != nil {
                    self.connection = nil
                    self.isSubscribed = false
                    self.reconnectAttempt += 1
                    self.onEvent?(.disconnected)
                    return
                }
                self.receiveLoop(connection)
            }
        }
    }

    /// Split the accumulated buffer into complete NDJSON lines and dispatch.
    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !lineData.isEmpty,
                let line = String(data: Data(lineData), encoding: .utf8)
            else { continue }
            parseLine(line)
        }
    }

    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let eventName = obj["event"] as? String,
            let dataObj = obj["data"] as? [String: Any]
        else { return }
        switch eventName {
        case "pane_updated", "pane_created":
            if let pane = dataObj["pane"] as? [String: Any],
                let parsed = HerdrStreamPane.fromJSON(pane)
            {
                onEvent?(.paneUpdated(parsed))
            }
        case "pane_closed":
            if let paneId = dataObj["pane_id"] as? String {
                onEvent?(.paneClosed(paneId: paneId))
            }
        case "pane_agent_detected":
            let paneId = dataObj["pane_id"] as? String ?? ""
            let agent = dataObj["agent"] as? String
            let status = dataObj["final_status"] as? String ?? dataObj["agent_status"] as? String
            onEvent?(.agentDetected(paneId: paneId, agent: agent, status: status))
        default:
            break
        }
    }

    private static func subscribeParamsJSON() -> String {
        let subs = subscriptions.map { "{\"type\":\"\($0)\"}" }
        return "{\"subscriptions\":[\(subs.joined(separator: ","))]}"
    }
}

extension HerdrStreamPane {
    static func fromJSON(_ obj: [String: Any]) -> HerdrStreamPane? {
        guard let paneId = obj["pane_id"] as? String else { return nil }
        return HerdrStreamPane(
            paneId: paneId,
            agent: obj["agent"] as? String,
            agentStatus: obj["agent_status"] as? String,
            cwd: obj["cwd"] as? String,
            workspaceId: obj["workspace_id"] as? String,
            terminalTitle: (obj["terminal_title_stripped"] as? String)
                ?? (obj["terminal_title"] as? String),
            focused: obj["focused"] as? Bool ?? false)
    }
}

/// Thread-safe once-only flag for settling a CheckedContinuation exactly one
/// time from a `@Sendable` state-update handler.
private final class SendableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func markOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
