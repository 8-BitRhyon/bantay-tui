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
    /// Working directory of the agent's pane (herdr poll). Used to derive a
    /// human project name + git branch so rows read "project · branch" instead
    /// of a bare tool name (so N claude agents stop looking identical).
    let cwd: String?
    /// Approval-prompt shape for blocked agents, merged from the event
    /// stream so the control plane can render yes/no, numbered choices, and
    /// multi-select inline. Nil for agents not blocked on an approval.
    let variance: ApprovalVariance?
    let choices: [String]?
    /// When this agent's current working burst began (elapsed timers).
    let startedAt: Date?
    /// Cached project context (project + git branch) derived from `cwd`.
    /// Computed ONCE per poll off the main actor (PERF-1) instead of being a
    /// computed property that re-reads `.git/HEAD` from disk on every SwiftUI
    /// body evaluation.
    let projectContext: ProjectContext?

    var approval: IslandMetrics.ApprovalControls {
        IslandMetrics.ApprovalControls(variance: variance, choices: choices)
    }
}

/// Project + branch identity for an agent's working directory.
struct ProjectContext: Equatable, Sendable {
    let project: String
    let branch: String?
    let isGit: Bool

    /// Short-lived per-cwd cache so `.git/HEAD` is read at most once per cwd
    /// per interval instead of on every poll's roster rebuild (the read runs
    /// on the main actor today; cwds are stable, so a memo is safe and cuts
    /// the beachball risk at startup when many agents exist).
    private static let cacheTTL: TimeInterval = 5.0
    nonisolated(unsafe) private static var cache: [String: (context: ProjectContext, at: Date)] =
        [:]
    private static let cacheLock = NSLock()

    init(cwd: String) {
        if let hit = Self.cached(cwd) {
            self = hit
            return
        }
        self.project = (cwd as NSString).lastPathComponent
        let headURL = URL(fileURLWithPath: cwd).appendingPathComponent(".git/HEAD")
        if let content = try? String(contentsOf: headURL, encoding: .utf8) {
            let parsed = Self.parseHead(content)
            self.branch = parsed.branch
            self.isGit = parsed.isGit
        } else {
            self.branch = nil
            self.isGit = false
        }
        Self.store(cwd, self)
    }

    private static func cached(_ cwd: String) -> ProjectContext? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let hit = cache[cwd],
            Date().timeIntervalSince(hit.at) < cacheTTL
        else { return nil }
        return hit.context
    }

    private static func store(_ cwd: String, _ context: ProjectContext) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[cwd] = (context, Date())
        if cache.count > 64 {
            let cutoff = Date().addingTimeInterval(-cacheTTL)
            cache = cache.filter { $0.value.at > cutoff }
        }
    }

    /// Pure parser for `.git/HEAD` contents (PERF-1). `ref: refs/heads/<b>`
    /// yields the branch; a bare hex (detached HEAD) yields "detached"; empty
    /// or garbage yields not-git. Harness-testable without disk I/O.
    static func parseHead(_ content: String) -> (branch: String?, isGit: Bool) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return (String(trimmed.dropFirst("ref: refs/heads/".count)), true)
        }
        if !trimmed.isEmpty {
            return ("detached", true)
        }
        return (nil, false)
    }
}

struct RecentCompletion: Identifiable, Equatable, Sendable {
    let id: String
    let source: String
    let kind: AgentEventKind
    let title: String?
    let createdAt: Date
    let duration: TimeInterval?

    init(
        id: String,
        source: String,
        kind: AgentEventKind,
        title: String?,
        createdAt: Date,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
    }
}

@MainActor
final class AgentEventManager: ObservableObject {
    @MainActor static let shared = AgentEventManager()

    @Published private(set) var currentEvent: AgentEvent?
    @Published private(set) var agents: [AgentSnapshot] = []
    @Published private(set) var recentCompletions: [RecentCompletion] = []
    /// Aggregate token/cost usage from agent transcripts (gauge in footer).
    @Published private(set) var usage: UsageSnapshot = .zero
    /// Tokens/min over the last minute of transcript activity (rate segment).
    @Published private(set) var usageRate: UsageRate = UsageRate(
        tokensPerMinute: nil, lastSeen: nil)
    private var watchTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var streamRefreshTask: Task<Void, Never>?
    /// Last push-stream status/title per pane, to filter redundant events.
    private var lastStreamStatus: [String: String] = [:]
    private var lastStreamTitle: [String: String] = [:]
    private var clearTask: Task<Void, Never>?
    private var fileSource: DispatchSourceFileSystemObject?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    /// True while the display is locked (an approval arriving now must reach
    /// the user via Notification Center — the island can't be seen).
    private(set) var displayLocked = false
    private let eventStream = HerdrEventStream()
    private(set) var isActive = false
    private var displayAsleep = false
    private var readOffset: UInt64
    private var lineBuffer = ""
    private var lastSeenKinds: [String: AgentEventKind] = [:]
    private var lastSoundAt: [String: Date] = [:]
    /// PERF-2: last time the standalone ps scan ran (throttle state).
    private var lastStandaloneScan: Date?
    /// PERF-2: minimum interval between standalone `ps` scans.
    static let minScanInterval: TimeInterval = 30
    /// PERF-2: memoized transcript-root mtimes so unchanged trees skip the
    /// expensive enumeration + read on each poll.
    private var transcriptMtimes: [String: Date] = [:]
    /// Last kilo cumulative snapshot + poll interval, for tpm poll-and-diff.
    private var lastKiloSnapshot: UsageSnapshot?
    private var kiloPollInterval: TimeInterval = 2.0
    /// When each pane's current working burst started (for elapsed timers).
    /// Set when a pane transitions into progress/started; cleared when it
    /// leaves working state.
    private var startedAtByPane: [String: Date] = [:]
    /// Latest approval prompt shape per pane, decoded from the event stream.
    /// Merged into roster snapshots so queue cards can render yes/no,
    /// numbered-choice, and multi-select controls inline.
    var pendingApprovals: [String: (variance: ApprovalVariance?, choices: [String]?)] =
        [:]
    /// Panes with an in-flight approve/deny/choice/stop. The control plane
    /// marks a pane here the instant a user acts so the card shows a resolving
    /// state and cannot be double-fired (a synchronous `Process.waitUntilExit`
    /// in the adapter would otherwise block the island and invite a second
    /// click). Cleared when the next poll confirms the agent left the blocked
    /// state, or after a safety timeout.
    private var resolvingPanes: Set<String> = []
    /// Caps how long a pane stays in the resolving state if the next poll
    /// doesn't clear it (e.g. herdr daemon down).
    private let resolvingTimeout: TimeInterval = 4
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
        // Lock state: the distributed notifications are the macOS 13-safe
        // signal (NSWorkspace.didLockNotification is newer-SDK only). A
        // locked display means approvals must go to Notification Center.
        let distCenter = DistributedNotificationCenter.default()
        lockObserver = distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayLocked = true
            }
        }
        unlockObserver = distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayLocked = false
            }
        }
        start()
        startCapture()
    }

    func start() {
        watchTask?.cancel()
        watchTask = nil
        startFileWatcher()
        eventStream.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handleStreamEvent(event) }
        }
        eventStream.start()
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        captureTask?.cancel()
        captureTask = nil
        streamRefreshTask?.cancel()
        streamRefreshTask = nil
        clearTask?.cancel()
        clearTask = nil
        fileSource?.cancel()
        fileSource = nil
        eventStream.stop()
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let lockObserver {
            DistributedNotificationCenter.default().removeObserver(lockObserver)
        }
        if let unlockObserver {
            DistributedNotificationCenter.default().removeObserver(unlockObserver)
        }
    }

    /// Push event from the herdr subscription: trigger a roster refresh so
    /// status changes land on the island immediately instead of on the next
    /// poll tick. `disconnected` does a full refresh to rebuild state.
    private func handleStreamEvent(_ event: HerdrEventStream.StreamEvent) {
        switch event {
        case .paneUpdated(let pane):
            if pane.agentStatus != lastStreamStatus[pane.paneId]
                || pane.terminalTitle != lastStreamTitle[pane.paneId]
            {
                lastStreamStatus[pane.paneId] = pane.agentStatus
                lastStreamTitle[pane.paneId] = pane.terminalTitle
                scheduleStreamRefresh()
            }
        case .paneClosed(let paneId):
            // Prune dedup state so closed panes can't accumulate forever.
            lastStreamStatus.removeValue(forKey: paneId)
            lastStreamTitle.removeValue(forKey: paneId)
            scheduleStreamRefresh()
        case .agentDetected, .disconnected:
            scheduleStreamRefresh()
        }
    }

    /// Throttle push-triggered refreshes: coalesce a burst of pane events
    /// into one roster refresh shortly after the last one.
    private func scheduleStreamRefresh() {
        guard captureEnabled else { return }
        streamRefreshTask?.cancel()
        streamRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await self?.refreshRosterAndArmWaits()
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
    }

    /// Acknowledges completion/failure recents when the expanded panel opens.
    func markRecentCompletionsSeen() {
        recentCompletions.removeAll()
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
        // Muted sources are fully suppressed: no pill, no sound, no
        // bookkeeping. They only reappear after an unmute (Settings).
        if let source = event.source,
            NotchHUDConfig.shared.mutedSources.contains(source)
        {
            return
        }
        let key = event.identityKey
        // ntfy.sh push for events that need attention even away from the
        // terminal: approvals/blocked always; failures and completions too.
        if let source = event.source {
            AgentAlertNotifier.notify(
                source: source, kind: event.kind, title: event.title ?? event.message,
                paneId: event.paneId)
        }
        if event.kind == .accessRequest || event.kind == .waiting {
            pendingApprovals[key] = (variance: event.variance, choices: event.choices)
        } else if event.kind != .progress && event.kind != .started {
            pendingApprovals.removeValue(forKey: key)
            // The pane stopped blocking: drop any pending notification so a
            // stale Approve/Deny can't inject a keypress into the pane now.
            if event.paneId != nil || event.source != nil {
                let paneKey = event.paneId ?? event.source ?? key
                ApprovalNotificationController.shared.removeForPane(paneKey)
            }
        }
        var completionDuration: TimeInterval?
        if event.kind == .completed || event.kind == .failed {
            if let start = startedAtByPane[key] {
                completionDuration = event.createdAt.timeIntervalSince(start)
            }
            if event.kind == .completed {
                NotchHUDConfig.shared.addMascotXP(25)
            }
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

        if (event.kind == .completed || event.kind == .failed) && !isActive {
            let recent = RecentCompletion(
                id: "\(key):\(event.kind.rawValue):\(event.createdAt.timeIntervalSince1970)",
                source: event.sourceKey,
                kind: event.kind,
                title: event.title ?? event.message,
                createdAt: event.createdAt,
                duration: completionDuration)
            recentCompletions = Array(([recent] + recentCompletions).prefix(5))
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
        let projectContext: ProjectContext? = {
            guard let cwd = agent.cwd, !cwd.isEmpty else { return nil }
            return ProjectContext(cwd: cwd)
        }()
        // Unique id: paneId when present, else source + cwd. Multiple
        // pane-less agents of the same source (e.g. two herdr/freebuff
        // processes) must not share an id — ForEach(id:) and Dictionary
        // keyed on id would crash/duplicate.
        let id: String =
            agent.paneId
            ?? (agent.cwd.map { "\(agent.agent):\($0)" }
                ?? agent.agent + ":standalone")
        return AgentSnapshot(
            id: id,
            source: agent.agent,
            kind: kind,
            title: agent.terminalTitle,
            message: agent.agentStatus,
            paneId: agent.paneId,
            workspaceId: agent.workspaceId,
            cwd: agent.cwd,
            variance: nil,
            choices: nil,
            startedAt: nil,
            projectContext: projectContext
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
            // best is sorted ascending by severity; the fallback should
            // promote the most important remaining agent, not the least.
            let top = best.last,
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
        guard captureEnabled, NotchHUDConfig.shared.captureEnabled else { return }
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.displayAsleep else {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                // The push event stream keeps status live; the poll loop now
                // acts as a slow safety net (roster consistency, standalone
                // ps scan, transcript usage) instead of the source of truth.
                await self.refreshRosterAndArmWaits()
                try? await Task.sleep(
                    for: .seconds(Int64(NotchHUDConfig.shared.captureInterval)))
            }
        }
    }

    func stopCapture() {
        captureTask?.cancel()
        captureTask = nil
    }

    private func refreshRosterAndArmWaits() async {
        ensureFileWatcher()
        let herdrAgents: [HerdrAgentInfo] = await herdrAdapter.listAgents()
        let scanStandalone = NotchHUDConfig.shared.standaloneScanEnabled
        // Heavy scans (ps, transcript enumeration) run off the main actor so
        // the island never beachballs while polling. PERF-2: throttle the ps
        // spawn to `minScanInterval` — the roster is fine updating every few
        // seconds without re-scanning the process table each time.
        let rescan =
            scanStandalone
            && StandaloneAgentScanner.shouldRescan(
                lastScan: lastStandaloneScan, now: Date(),
                minInterval: Self.minScanInterval)
        if rescan {
            lastStandaloneScan = Date()
        }
        let agents: [HerdrAgentInfo] = await Task.detached(priority: .userInitiated) {
            let detected = rescan ? StandaloneAgentScanner.scan() : []
            return herdrAgents
                + detected.filter {
                    !Set(herdrAgents.map { $0.agent }).contains($0.name)
                }.map {
                    HerdrAgentInfo(
                        agent: $0.name,
                        agentStatus: "working",
                        paneId: nil,
                        workspaceId: nil,
                        terminalTitle: $0.activity,
                        cwd: nil
                    )
                }
        }.value
        // PERF: the transcript token/cost enumeration + disk read is gated
        // behind `usageTrackingEnabled`. Nothing in the UI renders usage (the
        // footer gauge was removed), so this was running every poll for data
        // nobody consumed. Phase C (spend history) re-enables it when there's
        // a consumer.
        if NotchHUDConfig.shared.usageTrackingEnabled {
            let hasKilo = agents.contains { $0.agent == "kilo" }
            let now = Date()
            if hasKilo, KiloUsageAdapter.detect() {
                // Kilo's ledger is SQLite — the authoritative source. Quota =
                // cost over the daily budget; tpm = poll-and-diff cumulative
                // totals over the poll interval (off-main, WAL-safe read).
                let pollInterval = NotchHUDConfig.shared.captureInterval
                let currentUsage = self.usage
                let currentRate = self.usageRate
                let lastKilo = self.lastKiloSnapshot
                let result = await Task.detached(priority: .utility) {
                    let day = KiloUsageAdapter.snapshot(since: 24 * 3600, now: now)
                    let window = KiloUsageAdapter.snapshot(since: 60, now: now)
                    let usage = day ?? UsageSnapshot.zero
                    let rate: UsageRate =
                        if let before = lastKilo, let after = window {
                            UsageRate(
                                tokensPerMinute: KiloUsageAdapter.rateFromDeltas(
                                    before: before, after: after, window: pollInterval))
                        } else if let window {
                            UsageRate(tokensPerMinute: Double(window.totalTokens))
                        } else {
                            currentRate
                        }
                    return (usage, rate)
                }.value
                self.usage = result.0
                self.usageRate = result.1
                self.lastKiloSnapshot = KiloUsageAdapter.snapshot(since: 60, now: now)
                _ = currentUsage
            } else {
                // Non-kilo agents: fall back to transcript parsing (codex/
                // claude/opencode) with the mtime memo.
                let usageRoots: Set<String> = Set(
                    agents.flatMap {
                        AgentDetector.transcriptSearchPaths(home: NSHomeDirectory(), name: $0.agent)
                    })
                let changedRoots = usageRoots.filter { root in
                    guard let mtime = UsageTracker.transcriptMtime(root: root) else { return true }
                    return transcriptMtimes[root] != mtime
                }
                for root in changedRoots {
                    transcriptMtimes[root] = UsageTracker.transcriptMtime(root: root)
                }
                let currentUsage = self.usage
                let currentRate = self.usageRate
                let usageAndRate = await Task.detached(priority: .utility) {
                    if changedRoots.isEmpty && currentUsage.totalTokens > 0 {
                        return (currentUsage, currentRate)
                    }
                    return UsageTracker.latestUsageAndRate(
                        home: NSHomeDirectory(),
                        names: agents.map { $0.agent },
                        now: Date(),
                        window: 60)
                }.value
                self.usage = usageAndRate.0
                self.usageRate = usageAndRate.1
            }
        }
        let liveStatuses: [String: String] = Dictionary(
            agents.compactMap {
                (agent: HerdrAgentInfo) -> (String, String)? in
                // Disambiguate pane-less agents of the same source by cwd so
                // duplicates are never silently dropped (the heartbeat would
                // miss one agent's transitions).
                let key: String =
                    agent.paneId
                    ?? (agent.cwd.map { "\(agent.agent):\($0)" }
                        ?? agent.agent + ":standalone")
                return (key, agent.agentStatus ?? "")
            },
            uniquingKeysWith: { first, _ in first })
        // Prune push-stream dedup caches against the live roster so a missed
        // pane_closed event (herdr restart, dropped event) can't grow them
        // unboundedly.
        let liveKeys = Set(liveStatuses.keys)
        lastStreamStatus = lastStreamStatus.filter { liveKeys.contains($0.key) }
        lastStreamTitle = lastStreamTitle.filter { liveKeys.contains($0.key) }
        heartbeatVerify(liveStatuses: liveStatuses)
        let result = Self.update(
            from: agents,
            lastSeenKinds: &lastSeenKinds,
            current: currentEvent)
        self.agents = mergeApprovals(into: result.roster)
        for event in result.events {
            showEvent(event)
        }

        let livePanes = Set(agents.compactMap { $0.paneId })
        // No per-pane `herdr agent wait` subprocesses: the push event stream
        // (HerdrEventStream) already wakes the roster on status changes, so
        // spawning a wait process per pane is redundant process spam.
        _ = livePanes
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
        // A poll that no longer reports a pane as blocked clears any stale
        // resolving flag so the optimistic card removal isn't stuck.
        for paneId in resolvingPanes
        where !result.roster.contains(where: {
            $0.paneId == paneId
                && ($0.kind == .accessRequest || $0.kind == .waiting)
        }) {
            resolvingPanes.remove(paneId)
        }
    }

    /// Attach the latest decoded approval prompt (variance/choices) and the
    /// working-burst start time to roster rows so the control plane renders
    /// the full interactive surface and elapsed timers.
    func mergeApprovals(into roster: [AgentSnapshot]) -> [AgentSnapshot] {
        let muted = NotchHUDConfig.shared.mutedSources
        return roster.compactMap { agent in
            guard !muted.contains(agent.source) else { return nil }
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
                cwd: agent.cwd,
                variance: variance,
                choices: choices,
                startedAt: startedAt,
                projectContext: agent.projectContext
            )
        }
    }

    /// True while an action is in flight for `paneId` — the control plane
    /// disables its buttons and shows a resolving state to prevent re-fire.
    func isResolving(paneId: String) -> Bool {
        resolvingPanes.contains(paneId)
    }

    /// Convenience: resolves the agent's paneId and checks `isResolving`.
    func isResolving(agent: AgentSnapshot?) -> Bool {
        guard let paneId = agent?.paneId else { return false }
        return resolvingPanes.contains(paneId)
    }

    /// Fire an adapter action off the main actor (the adapter does blocking
    /// `Process.waitUntilExit` I/O) and optimistically mark the pane as
    /// resolving so the UI can't double-fire and feels instant. The resolving
    /// flag clears on the next confirming poll, or after `resolvingTimeout`.
    func performAction(
        paneId: String, _ action: @escaping @Sendable (HerdrSocketAdapter) -> Void
    ) {
        resolvingPanes.insert(paneId)
        let adapter = herdrAdapter
        Task.detached {
            action(adapter)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(self.resolvingTimeout))
                self.resolvingPanes.remove(paneId)
            }
        }
    }

    /// Drop a pane from the resolving set immediately — called when a poll
    /// confirms the agent is no longer blocked/working (avoids the 4s wait).
    func clearResolving(paneId: String) {
        resolvingPanes.remove(paneId)
    }

    /// Test seam: record a working-burst start time (mirrors showEvent).
    func recordStartForTesting(pane: String, at date: Date) {
        startedAtByPane[pane] = date
    }

    /// Test seam: clear a working-burst start time (mirrors showEvent).
    func clearStartForTesting(pane: String) {
        startedAtByPane.removeValue(forKey: pane)
    }

    /// Test seam: inject an event like the pipeline would.
    func publishEventForTesting(_ event: AgentEvent) {
        showEvent(event)
    }

    /// Test seam: current event readout for harness assertions.
    var currentEventForTesting: AgentEvent? { currentEvent }

    /// Heartbeat: every roster poll re-verifies pinned approvals against live
    /// agent state. Panes that are no longer blocked (or vanished) drop their
    /// pending prompts — killing phantom prompts from dropped hooks. Missing
    /// live data keeps the prompt pinned (never phantom-clear on unknowns).
    func heartbeatVerify(liveStatuses: [String: String]) {
        let stale = Set(pendingApprovals.keys).subtracting(
            IslandMetrics.ApprovalHeartbeat.verifyPendingKeys(
                Array(pendingApprovals.keys), liveStatuses: liveStatuses))
        for key in stale {
            pendingApprovals.removeValue(forKey: key)
        }
        if let current = currentEvent,
            current.kind == .accessRequest || current.kind == .waiting,
            let status = liveStatuses[current.identityKey],
            !IslandMetrics.ApprovalHeartbeat.shouldKeepPinned(
                kind: current.kind, liveStatus: status)
        {
            currentEvent = nil
            clearTask?.cancel()
        }
    }

    /// Ingest a remote event line (SSH bridge or Claude Code hook): validates
    /// the payload — mapping Claude hook payloads to Bantay events — then
    /// appends it to the watched events file so the file watcher surfaces it
    /// like any local event.
    func ingestEventLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }

        var payloadData = data
        if (try? JSONDecoder().decode(AgentEventPayload.self, from: data)) == nil,
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let mapped = ClaudeHookInstaller.mapToEventPayload(obj),
            let mappedData = try? JSONSerialization.data(withJSONObject: mapped)
        {
            payloadData = mappedData
        }
        guard let payloadText = String(data: payloadData, encoding: .utf8),
            (try? JSONDecoder().decode(AgentEventPayload.self, from: payloadData)) != nil
        else {
            return
        }
        if !FileManager.default.fileExists(atPath: eventsFileURL.path) {
            FileManager.default.createFile(atPath: eventsFileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: eventsFileURL) else { return }
        defer { try? handle.close() }
        if let end = try? handle.seekToEnd() {
            _ = end
        }
        handle.write(Data((payloadText + "\n").utf8))
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
                terminalTitle: $0.activity,
                cwd: nil
            )
        }
        return herdr + extras
    }
}

/// Decoder shape for event lines arriving via the events file, the Claude
/// hook, or the ingest listeners (TCP + UDS). Kept internal so the UDS
/// bare-line validator (`EventIngestServer.validateBareLine`) reuses the
/// exact same decoder path as `ingestEventLine`.
struct AgentEventPayload: Decodable {
    let source: String?
    let type: AgentEventKind?
    let title: String?
    let message: String?
    let paneId: String?
    let workspaceId: String?
    let variance: ApprovalVariance?
    let choices: [String]?
}
