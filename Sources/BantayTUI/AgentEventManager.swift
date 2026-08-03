import AppKit
import Combine
import Foundation

struct AgentEvent: Identifiable, Equatable {
    let id = UUID()
    let source: String?
    let kind: AgentEventKind
    let title: String?
    let message: String?
    let paneId: String?
    let workspaceId: String?
    let variance: ApprovalVariance?
    let choices: [String]?
    let playSound: Bool
    let persistent: Bool
    let createdAt = Date()

    var effectiveVariance: ApprovalVariance {
        variance ?? .yesNo
    }

    var sourceKey: String {
        source ?? "herdr"
    }

    var identityKey: String {
        paneId ?? source ?? "unknown"
    }
}

struct AgentSnapshot: Identifiable, Equatable {
    let id: String
    let source: String
    let kind: AgentEventKind
    let title: String?
    let message: String?
    let paneId: String?
    let workspaceId: String?
    /// Approval-prompt shape for blocked agents, merged from the event
    /// stream so the control plane can render yes/no, numbered choices, and
    /// multi-select inline. Nil for agents not blocked on an approval.
    let variance: ApprovalVariance?
    let choices: [String]?
    /// When this agent's current working burst began (elapsed timers).
    let startedAt: Date?

    var approval: IslandMetrics.ApprovalControls {
        IslandMetrics.ApprovalControls(variance: variance, choices: choices)
    }
}

@MainActor
final class AgentEventManager: ObservableObject {
    @MainActor static let shared = AgentEventManager()

    @Published private(set) var currentEvent: AgentEvent?
    @Published private(set) var agents: [AgentSnapshot] = []
    private var watchTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var waitProcesses: [String: Process] = [:]
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private var waitSignalCount = 0
    private var clearTask: Task<Void, Never>?
    private var fileSource: DispatchSourceFileSystemObject?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private(set) var isActive = false
    private var displayAsleep = false
    private var readOffset: UInt64
    private var lineBuffer = ""
    private var lastSeenKinds: [String: AgentEventKind] = [:]
    private var lastSoundAt: [String: Date] = [:]
    /// When each pane's current working burst started (for elapsed timers).
    /// Set when a pane transitions into progress/started; cleared when it
    /// leaves working state.
    private var startedAtByPane: [String: Date] = [:]
    /// Latest approval prompt shape per pane, decoded from the event stream.
    /// Merged into roster snapshots so queue cards can render yes/no,
    /// numbered-choice, and multi-select controls inline.
    var pendingApprovals: [String: (variance: ApprovalVariance?, choices: [String]?)] =
        [:]
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
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObserver = workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayAsleep = true
            }
        }
        wakeObserver = workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayAsleep = false
            }
        }
        start()
        startCapture()
    }

    func start() {
        watchTask?.cancel()
        watchTask = nil
        startFileWatcher()
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        captureTask?.cancel()
        captureTask = nil
        clearTask?.cancel()
        clearTask = nil
        fileSource?.cancel()
        fileSource = nil
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
    }

    func shouldPlaySound(for event: AgentEvent) -> Bool {
        let key = "\(event.sourceKey):\(event.kind)"
        let now = Date()
        if let last = lastSoundAt[key],
            now.timeIntervalSince(last) < NotchHUDConfig.shared.soundCooldown
        {
            return false
        }
        lastSoundAt[key] = now
        return true
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
                    variance: .yesNo,
                    choices: nil,
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
        let key = event.identityKey
        if event.kind == .accessRequest || event.kind == .waiting {
            pendingApprovals[key] = (variance: event.variance, choices: event.choices)
        } else if event.kind != .progress && event.kind != .started {
            pendingApprovals.removeValue(forKey: key)
        }
        if event.kind == .progress || event.kind == .started {
            if startedAtByPane[key] == nil {
                startedAtByPane[key] = event.createdAt
            }
        } else if event.kind == .completed || event.kind == .failed
            || event.kind == .cancelled || event.kind == .clear
        {
            startedAtByPane.removeValue(forKey: key)
        }

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
            && config.stickyApprovalSources.contains(event.sourceKey.lowercased())
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
            variance: payload.variance,
            choices: payload.choices,
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
            workspaceId: agent.workspaceId,
            variance: nil,
            choices: nil,
            startedAt: nil
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
                    variance: nil,
                    choices: nil,
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
            let key = event.identityKey
            let prev = lastSeenKinds[key]
            lastSeenKinds[key] = event.kind
            if prev != event.kind {
                events.append(event)
            }
        }

        // Keep lastSeenKinds sticky: a pane that vanishes and re-enters with the
        // same kind must re-show silently (no new event), per the silent-reshow
        // invariant. No purge here.
        let liveKeys = Set(best.map { $0.paneId ?? $0.source })

        if let current, current.persistent, !liveKeys.contains(current.paneId ?? current.source) {
            events.append(
                AgentEvent(
                    source: current.source,
                    kind: .clear,
                    title: nil,
                    message: nil,
                    paneId: current.paneId,
                    workspaceId: current.workspaceId,
                    variance: nil,
                    choices: nil,
                    playSound: false,
                    persistent: false
                ))
        }

        events.sort { severity(of: $0.kind) < severity(of: $1.kind) }

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
            lastSeenKinds[top.identityKey] == top.kind,
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
                    variance: nil,
                    choices: nil,
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
        signalWaitExit()
        for process in waitProcesses.values {
            process.terminate()
        }
        waitProcesses.removeAll()
        guard captureEnabled, NotchHUDConfig.shared.captureEnabled else { return }
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.displayAsleep else {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                await self.refreshRosterAndArmWaits()
                if self.waitProcesses.isEmpty {
                    try? await Task.sleep(
                        for: .milliseconds(Int64(NotchHUDConfig.shared.idlePollInterval * 1000)))
                } else {
                    await self.awaitWaitExit()
                }
            }
        }
    }

    func stopCapture() {
        captureTask?.cancel()
        captureTask = nil
        for process in waitProcesses.values {
            process.terminate()
        }
        waitProcesses.removeAll()
        signalWaitExit()
    }

    private func refreshRosterAndArmWaits() async {
        ensureFileWatcher()
        let herdrAgents = await herdrAdapter.listAgents()
        let agents = mergeStandalone(
            into: herdrAgents,
            detected: NotchHUDConfig.shared.standaloneScanEnabled
                ? StandaloneAgentScanner.scan() : [])
        let result = Self.update(
            from: agents,
            lastSeenKinds: &lastSeenKinds,
            current: currentEvent)
        self.agents = mergeApprovals(into: result.roster)
        for event in result.events {
            showEvent(event)
        }

        let livePanes = Set(agents.compactMap(\.paneId))
        let stale = waitProcesses.keys.filter { !livePanes.contains($0) }
        for pane in stale {
            waitProcesses[pane]?.terminate()
            waitProcesses.removeValue(forKey: pane)
        }

        for agent in agents {
            guard let pane = agent.paneId, waitProcesses[pane] == nil else { continue }
            var statuses = Set(["idle", "working", "blocked", "done", "unknown"])
            if let status = agent.agentStatus {
                statuses.remove(status)
            }
            guard let process = herdrAdapter.spawnAgentWait(paneId: pane, statuses: Array(statuses))
            else { continue }
            waitProcesses[pane] = process
            process.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.waitProcesses[pane] === process else { return }
                    self.waitProcesses.removeValue(forKey: pane)
                    self.signalWaitExit()
                }
            }
        }
    }

    private func awaitWaitExit() async {
        let base = waitSignalCount
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if waitSignalCount != base {
                continuation.resume()
            } else {
                waitContinuation = continuation
            }
        }
    }

    private func signalWaitExit() {
        waitSignalCount += 1
        if let continuation = waitContinuation {
            waitContinuation = nil
            continuation.resume()
        }
    }

    private func startFileWatcher() {
        fileSource?.cancel()
        fileSource = nil
        guard captureEnabled else { return }
        let fd = open(eventsFileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    private func ensureFileWatcher() {
        guard fileSource == nil else { return }
        startFileWatcher()
    }

    func pollHerdrAgents() async {
        let agents = await herdrAdapter.listAgents()
        let result = Self.update(
            from: agents,
            lastSeenKinds: &lastSeenKinds,
            current: currentEvent)
        self.agents = mergeApprovals(into: result.roster)
        for event in result.events {
            showEvent(event)
        }
    }

    /// Attach the latest decoded approval prompt (variance/choices) and the
    /// working-burst start time to roster rows so the control plane renders
    /// the full interactive surface and elapsed timers.
    func mergeApprovals(into roster: [AgentSnapshot]) -> [AgentSnapshot] {
        roster.map { agent in
            let key = agent.paneId ?? agent.source
            var variance = agent.variance
            var choices = agent.choices
            if agent.kind == .accessRequest || agent.kind == .waiting,
                let pending = pendingApprovals[key]
            {
                variance = pending.variance
                choices = pending.choices
            }
            let startedAt = startedAtByPane[key]
            return AgentSnapshot(
                id: agent.id,
                source: agent.source,
                kind: agent.kind,
                title: agent.title,
                message: agent.message,
                paneId: agent.paneId,
                workspaceId: agent.workspaceId,
                variance: variance,
                choices: choices,
                startedAt: startedAt
            )
        }
    }

    /// Test seam: record a working-burst start time (mirrors showEvent).
    func recordStartForTesting(pane: String, at date: Date) {
        startedAtByPane[pane] = date
    }

    /// Test seam: clear a working-burst start time (mirrors showEvent).
    func clearStartForTesting(pane: String) {
        startedAtByPane.removeValue(forKey: pane)
    }

    /// Merge standalone-detected agents into the herdr roster without
    /// duplicating agents herdr already manages (matched by canonical name).
    func mergeStandalone(
        into herdr: [HerdrAgentInfo], detected: [DetectedAgent]
    ) -> [HerdrAgentInfo] {
        let herdrNames = Set(herdr.map(\.agent))
        let extras = detected.filter { !herdrNames.contains($0.name) }.map {
            HerdrAgentInfo(
                agent: $0.name,
                agentStatus: "working",
                paneId: nil,
                workspaceId: nil,
                terminalTitle: $0.activity
            )
        }
        return herdr + extras
    }
}

private struct AgentEventPayload: Decodable {
    let source: String?
    let type: AgentEventKind?
    let title: String?
    let message: String?
    let paneId: String?
    let workspaceId: String?
    let variance: ApprovalVariance?
    let choices: [String]?
}
