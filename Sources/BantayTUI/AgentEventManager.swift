import Foundation
import Combine

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
    private var readOffset: UInt64 = 0
    private let eventsFileURL: URL

    init(eventsFileURL: URL? = nil) {
        self.eventsFileURL = eventsFileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bantay-TUI/agent-events.jsonl", isDirectory: false)
        start()
    }

    func start() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    self?.readPendingEvents()
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

    private func readPendingEvents() {
        guard FileManager.default.fileExists(atPath: eventsFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: eventsFileURL)
            guard let rawText = String(data: data, encoding: .utf8) else { return }
            let lines = rawText.split(whereSeparator: \.isNewline)
            for line in lines {
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                guard let lineData = text.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(AgentEventPayload.self, from: lineData) else {
                    continue
                }
                if let event = makeEvent(from: payload) {
                    showEvent(event)
                }
            }
        } catch {
            return
        }
    }

    private func showEvent(_ event: AgentEvent) {
        currentEvent = event
        clearTask?.cancel()

        let config = NotchHUDConfig.shared
        let ttl: TimeInterval

        if event.kind == .accessRequest && config.stickyApprovalSources.contains(event.source.lowercased()) {
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
        let kind = payload.type ?? .completed
        guard AgentEventKind(rawValue: kind.rawValue) != nil else { return nil }
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
