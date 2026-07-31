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
    let createdAt = Date()
}

@MainActor
final class AgentEventManager: ObservableObject {
    @Published private(set) var currentEvent: AgentEvent?
    private var watchTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var readOffset: UInt64
    private var lineBuffer = ""
    private let eventsFileURL: URL

    init(eventsFileURL: URL? = nil) {
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
        clearTask?.cancel()
        clearTask = nil
    }

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
            workspaceId: payload.workspaceId
        )
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
