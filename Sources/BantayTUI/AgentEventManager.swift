import Combine
import Foundation

struct AgentEvent: Identifiable, Equatable {
    let id = UUID()
    let source: String
    let kind: AgentEventKind
    let title: String?
    let message: String?
    let paneId: String?
    let workspaceId: String?
    let playSound: Bool
    let persistent: Bool
    let createdAt = Date()
}

struct AgentSnapshot: Identifiable, Equatable {
    let id: String
    let source: String
    let kind: AgentEventKind
    let title: String?
    let message: String?
    let paneId: String?
    let workspaceId: String?
}

@MainActor
final class AgentEventManager: ObservableObject {
    @MainActor static let shared = AgentEventManager()

    @Published private(set) var currentEvent: AgentEvent?
    @Published private(set) var agents: [AgentSnapshot] = []
    private var watchTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var readOffset: UInt64
    private var lineBuffer = ""
    private var lastSeenKinds: [String: AgentEventKind] = [:]
    private let eventsFileURL: URL
    private let captureEnabled: Bool
    private let herdrAdapter = HerdrSocketAdapter()

    init(eventsFileURL: URL? = nil, capture: Bool = true) {
        self.captureEnabled = capture
        let url =
            eventsFileURL
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bantay-TUI/agent-events.jsonl", isDirectory: false)
        self.eventsFileURL = url
        if let handle = try? FileHandle(forReadingFrom: url) {
            readOffset = (try? handle.seekToEnd()) ?? 0
            try? handle.close()
        } else {
            readOffset = 0
        }
        start()
        startCapture()
    }

    func start() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    self?.poll()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        captureTask?.cancel()
        captureTask = nil
        clearTask?.cancel()
        clearTask = nil
    }

    #if DEBUG
        func publishForTesting() {
            showEvent(
                AgentEvent(
                    source: "kilo",
                    kind: .accessRequest,
                    title: "Test alert",
                    message: nil,
                    paneId: nil,
                    workspaceId: nil,
                    playSound: true,
                    persistent: true
                ))
        }
    #endif

    func poll() {
        guard let handle = try? FileHandle(forReadingFrom: eventsFileURL) else { return }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return }
        if end < readOffset {
            readOffset = 0
        }
        guard end > readOffset else { return }
        try? handle.seek(toOffset: readOffset)
        let data = handle.readDataToEndOfFile()
        readOffset = end

        guard let text = String(data: data, encoding: .utf8) else { return }
        lineBuffer += text

        var lines = lineBuffer.split(whereSeparator: \.isNewline)
        if !lineBuffer.hasSuffix("\n"), let partial = lines.popLast() {
            lineBuffer = String(partial)
        } else {
            lineBuffer = ""
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                let lineData = trimmed.data(using: .utf8),
                let payload = try? JSONDecoder().decode(AgentEventPayload.self, from: lineData),
                let event = makeEvent(from: payload)
            else {
                continue
            }
            showEvent(event)
        }
    }

    private func showEvent(_ event: AgentEvent) {
        if event.kind == .clear {
            currentEvent = nil
            clearTask?.cancel()
            return
        }

        if let current = currentEvent,
            current.source == event.source,
            current.kind == event.kind,
            current.paneId == event.paneId
        {
            return
        }

        currentEvent = event
        clearTask?.cancel()

        guard !event.persistent else { return }

        let config = NotchHUDConfig.shared
        let ttl: TimeInterval

        if event.kind == .accessRequest
            && config.stickyApprovalSources.contains(event.source.lowercased())
        {
            ttl = config.stickyApprovalTTL
        } else if event.kind == .accessRequest {
            ttl = config.autoClearTTL * 3
        } else {
            ttl = config.autoClearTTL
        }

        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ttl))
            await MainActor.run {
                if self?.currentEvent?.id == event.id {
                    self?.currentEvent = nil
                }
            }
        }
    }

    private func makeEvent(from payload: AgentEventPayload) -> AgentEvent? {
        guard let kind = payload.type, AgentEventKind(rawValue: kind.rawValue) != nil else {
            return nil
        }
        let eventKind = AgentEventKind(rawValue: kind.rawValue)!
        return AgentEvent(
            source: payload.source ?? "herdr",
            kind: eventKind,
            title: payload.title,
            message: payload.message,
            paneId: payload.paneId,
            workspaceId: payload.workspaceId,
            playSound: true,
            persistent: false
        )
    }
}

extension AgentEventManager {
    nonisolated static func kind(for status: String) -> AgentEventKind? {
        switch status {
        case "blocked": return .accessRequest
        case "done": return .completed
        case "working": return .progress
        case "running": return .started
        case "idle": return .idle
        case "failed": return .failed
        case "cancelled": return .cancelled
        default: return nil
        }
    }

    nonisolated static func severity(of kind: AgentEventKind) -> Int {
        switch kind {
        case .accessRequest: return 4
        case .completed, .failed: return 3
        case .progress, .started: return 2
        case .waiting: return 1
        case .cancelled: return 1
        case .idle, .clear: return 0
        }
    }

    nonisolated static func snapshot(for agent: HerdrAgentInfo) -> AgentSnapshot? {
        guard let kind = kind(for: agent.agentStatus ?? "") else { return nil }
        return AgentSnapshot(
            id: agent.paneId ?? agent.agent,
            source: agent.agent,
            kind: kind,
            title: agent.terminalTitle,
            message: agent.agentStatus,
            paneId: agent.paneId,
            workspaceId: agent.workspaceId
        )
    }

    nonisolated static func update(
        from agents: [HerdrAgentInfo],
        lastSeenKinds: inout [String: AgentEventKind],
        current: AgentEvent?
    ) -> (roster: [AgentSnapshot], events: [AgentEvent]) {
        let roster = agents.compactMap { snapshot(for: $0) }
            .sorted { severity(of: $0.kind) > severity(of: $1.kind) }

        var grouped: [String: [AgentEvent]] = [:]
        for agent in agents {
            guard let kind = kind(for: agent.agentStatus ?? ""), kind != .idle else { continue }
            let key = agent.paneId ?? agent.agent
            grouped[key, default: []].append(
                AgentEvent(
                    source: agent.agent,
                    kind: kind,
                    title: agent.terminalTitle,
                    message: agent.agentStatus,
                    paneId: agent.paneId,
                    workspaceId: agent.workspaceId,
                    playSound: true,
                    persistent: kind.isOngoing
                ))
        }

        let best = grouped.compactMap { _, events in
            events.max { severity(of: $0.kind) < severity(of: $1.kind) }
        }
        .sorted { severity(of: $0.kind) < severity(of: $1.kind) }

        var events: [AgentEvent] = []
        for event in best {
            let key = event.paneId ?? event.source
            let prev = lastSeenKinds[key]
            lastSeenKinds[key] = event.kind
            if prev != event.kind {
                events.append(event)
            }
        }

        let liveKeys = Set(best.map { $0.paneId ?? $0.source })
        lastSeenKinds = lastSeenKinds.filter { liveKeys.contains($0.key) }

        if let current, current.persistent, !liveKeys.contains(current.paneId ?? current.source) {
            events.append(
                AgentEvent(
                    source: current.source,
                    kind: .clear,
                    title: nil,
                    message: nil,
                    paneId: current.paneId,
                    workspaceId: current.workspaceId,
                    playSound: false,
                    persistent: false
                ))
        }

        var effective = current
        for event in events {
            if event.kind == .clear {
                effective = nil
            } else if let cur = effective,
                cur.source == event.source,
                cur.kind == event.kind,
                cur.paneId == event.paneId
            {
                continue
            } else {
                effective = event
            }
        }

        if effective == nil,
            let top = best.first,
            lastSeenKinds[top.paneId ?? top.source] == top.kind,
            !events.contains(where: { $0.paneId ?? $0.source == top.paneId ?? top.source })
        {
            events.append(
                AgentEvent(
                    source: top.source,
                    kind: top.kind,
                    title: top.title,
                    message: top.message,
                    paneId: top.paneId,
                    workspaceId: top.workspaceId,
                    playSound: false,
                    persistent: top.persistent
                ))
        }

        return (roster, events)
    }
}

@MainActor
extension AgentEventManager {
    func startCapture() {
        captureTask?.cancel()
        guard captureEnabled, NotchHUDConfig.shared.captureEnabled else { return }
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollHerdrAgents()
                try? await Task.sleep(
                    for: .milliseconds(Int64(NotchHUDConfig.shared.captureInterval * 1000)))
            }
        }
    }

    func pollHerdrAgents() async {
        let agents = await herdrAdapter.listAgents()
        let result = Self.update(
            from: agents,
            lastSeenKinds: &lastSeenKinds,
            current: currentEvent)
        self.agents = result.roster
        for event in result.events {
            showEvent(event)
        }
    }
}

private struct AgentEventPayload: Decodable {
    let source: String?
    let type: AgentEventKind?
    let title: String?
    let message: String?
    let paneId: String?
    let workspaceId: String?
}
