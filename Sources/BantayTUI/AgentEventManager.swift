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
    /// Parallel to `choices`: option descriptions when the prompt has them.
    let choiceDetails: [String]?
    /// When this agent's current working burst began (elapsed timers).
    let startedAt: Date?
    /// Cached project context (project + git branch) derived from `cwd`.
    /// Computed ONCE per poll off the main actor (PERF-1) instead of being a
    /// computed property that re-reads `.git/HEAD` from disk on every SwiftUI
    /// body evaluation.
    let projectContext: ProjectContext?
    /// Path to the agent's transcript/session directory on disk if known.
    let sessionPath: String?
    /// True only when the blocked prompt is a real permission request with a
    /// concrete request or choices. False means "waiting for you": review the
    /// terminal instead of blind approve/deny.
    let approvalActionable: Bool
    let approvalRisk: AgentRisk

    init(
        id: String,
        source: String,
        kind: AgentEventKind,
        title: String?,
        message: String?,
        paneId: String?,
        workspaceId: String?,
        cwd: String?,
        variance: ApprovalVariance?,
        choices: [String]?,
        choiceDetails: [String]? = nil,
        startedAt: Date?,
        projectContext: ProjectContext?,
        sessionPath: String? = nil,
        approvalActionable: Bool = true,
        approvalRisk: AgentRisk = .low
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.title = title
        self.message = message
        self.paneId = paneId
        self.workspaceId = workspaceId
        self.cwd = cwd
        self.variance = variance
        self.choices = choices
        self.choiceDetails = choiceDetails
        self.startedAt = startedAt
        self.projectContext = projectContext
        self.sessionPath = sessionPath
        self.approvalActionable = approvalActionable
        self.approvalRisk = approvalRisk
    }

    var approval: IslandMetrics.ApprovalControls {
        IslandMetrics.ApprovalControls(
            variance: variance, choices: choices, details: choiceDetails)
    }

    var isWorking: Bool {
        kind == .progress || kind == .started
    }
}

/// Project + branch identity for an agent's working directory.
struct ProjectContext: Equatable, Sendable {
    let project: String
    let branch: String?
    let isGit: Bool
    let diffStat: String?

    /// Short-lived cache for Git repository branch and status.
    private static let cacheTTL: TimeInterval = 5.0
    nonisolated(unsafe) private static var cache: [String: (context: ProjectContext, at: Date)] =
        [:]
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var warming: Set<String> = []

    init(project: String, branch: String?, isGit: Bool, diffStat: String? = nil) {
        self.project = project
        self.branch = branch
        self.isGit = isGit
        self.diffStat = diffStat
    }

    init(cwd: String, diffStat: String? = nil) {
        if let hit = Self.cached(cwd) {
            if let diffStat, hit.diffStat != diffStat {
                let updated = ProjectContext(
                    project: hit.project, branch: hit.branch, isGit: hit.isGit, diffStat: diffStat)
                Self.store(cwd, updated)
                self = updated
                return
            }
            self = hit
            return
        }
        self.project = (cwd as NSString).lastPathComponent
        self.diffStat = diffStat
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

    /// Build a project context without touching disk on the caller's thread.
    /// The branch arrives on the next poll after a detached warm-up. The
    /// roster builder runs on the main actor, so a slow or network-backed
    /// `.git/HEAD` must never block the UI.
    static func cachedOrPlaceholder(cwd: String) -> ProjectContext {
        if let hit = Self.cached(cwd) { return hit }
        let placeholder = ProjectContext(
            project: (cwd as NSString).lastPathComponent,
            branch: nil,
            isGit: false)
        let alreadyWarming = Self.markWarming(cwd)
        guard !alreadyWarming else { return placeholder }
        Task.detached(priority: .utility) {
            _ = ProjectContext(cwd: cwd)
            Self.unmarkWarming(cwd)
        }
        return placeholder
    }

    private static func markWarming(_ cwd: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if warming.contains(cwd) { return true }
        warming.insert(cwd)
        return false
    }

    private static func unmarkWarming(_ cwd: String) {
        cacheLock.lock()
        warming.remove(cwd)
        cacheLock.unlock()
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

    /// Pure parser for git shortstat lines (e.g. "2 files changed, 14 insertions(+), 3 deletions(-)").
    /// Returns compact representation like "+14 -3" or nil.
    static func parseDiffStat(_ shortstat: String) -> String? {
        let trimmed = shortstat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var ins = ""
        var del = ""
        let parts = trimmed.components(separatedBy: ",")
        for part in parts {
            let lower = part.lowercased()
            if lower.contains("insertion") {
                let nums = part.filter { $0.isNumber }
                if !nums.isEmpty { ins = "+\(nums)" }
            } else if lower.contains("deletion") {
                let nums = part.filter { $0.isNumber }
                if !nums.isEmpty { del = "-\(nums)" }
            }
        }
        let joined = [ins, del].filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
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

/// Latest approval detail for one pane. The event stream often carries only
/// a blocked status, so the manager enriches this from the live pane or
/// transcript before the UI decides to show Allow and Deny.
struct PendingApproval: Equatable, Sendable {
    let eventID: UUID
    let title: String?
    let message: String?
    let variance: ApprovalVariance?
    let choices: [String]?
    /// Parallel to `choices`: option descriptions when the prompt has them.
    let choiceDetails: [String]?
    let actionable: Bool
    let risk: AgentRisk
    let prompt: ApprovalPrompt?

    var fingerprint: String {
        if let prompt, !prompt.isEmpty { return prompt.fingerprint }
        return [
            title ?? "", message ?? "",
            (choices ?? []).joined(separator: "|"),
        ].joined(separator: "|")
    }

    var customChoiceNumber: Int? {
        prompt?.customChoiceNumber
    }

    var needsEnrichment: Bool {
        guard let prompt else { return true }
        if prompt.isEmpty { return true }
        // Waiting events often carry only a status. Capture the pane even when
        // the title is concrete, because an OpenCode question keeps its
        // choices in the rendered form rather than in the event payload.
        if prompt.choices.isEmpty,
            prompt.kind == .question || prompt.kind == .waiting
                || prompt.kind == .unknown
        {
            return true
        }
        return prompt.actionable && prompt.choices.isEmpty && prompt.variance == nil
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
    /// Cached standalone detected agents between scans (prevent wiping roster between ticks).
    private var lastDetectedAgents: [DetectedAgent] = []
    private var activeScanTask: Task<[DetectedAgent], Never>?
    private var isRefreshingRoster = false
    /// PERF-2: minimum interval between standalone `ps` scans.
    /// Standalone transcripts have no push channel, but their status does
    /// not need sub-10s resolution. Each scan is a `ps` spawn plus tail parse.
    static let minScanInterval: TimeInterval = 10.0
    /// Standalone discovery can idle slower while no detected agent is
    /// working; herdr panes still arrive over the push stream.
    static let idleScanInterval: TimeInterval = 20.0
    /// PERF-2: memoized transcript-root mtimes so unchanged trees skip the
    /// expensive enumeration + read on each poll.
    private var transcriptMtimes: [String: Date] = [:]
    /// Last kilo cumulative snapshot + poll interval, for tpm poll-and-diff.
    private var lastKiloSnapshot: UsageSnapshot?
    private var kiloPollInterval: TimeInterval = 2.0
    /// Direction B: Budget & Quota active alert tracking state.
    private var didAlertBudget80 = false
    private var didAlertBudget100 = false
    private var lastBudgetAlertDay: Int = Calendar.current.component(.day, from: Date())
    private var lastHighBurnAlertDate: Date?
    /// When each pane's current working burst started (for elapsed timers).
    /// Set when a pane transitions into progress/started; cleared when it
    /// leaves working state.
    private var startedAtByPane: [String: Date] = [:]
    /// Per-source usage snapshot when a session started working. Completion
    /// records current-minus-baseline so rows show their own spend, never
    /// the lifetime cumulative total.
    private var usageBaselineByKey: [String: (tokens: Int, cost: Double)] = [:]
    /// Monotonic lifetime per-source counters feeding those baselines.
    /// Rolling-window snapshots slide as old activity ages out, so deltas
    /// must come from here. Transcripts accrue incrementally; the opencode
    /// ledger refreshes on file change.
    private var lifetimeAccrual = UsageTracker.LifetimeAccrualState()
    private var lifetimeOpencodeRevision: UInt64 = 0
    /// Full transcript sweeps are expensive; 30s is enough for session
    /// deltas without burning a core every poll.
    private let lifetimeAccrualInterval: TimeInterval = 30
    private var lastLifetimeAccrualAt = Date.distantPast
    private var lastUsagePollAt = Date.distantPast
    /// Whether the baseline came from a covered source (true delta) or a
    /// rolling window (honest estimate). Pruned with the other per-pane maps.
    private var baselineCoveredByKey: [String: Bool] = [:]
    /// What the last completion for a pane recorded. One finish often
    /// arrives as several events with different titles (a terminal title
    /// from the roster poll, then a fallback from the event stream). The
    /// session path identifies the finish; the title is only a description,
    /// so a refire upgrades the row in place instead of doubling it.
    private struct CompletionMark: Sendable {
        var fingerprint: String
        var title: String
        var tokens: Int
        var rowId: String
        /// Baseline the recorded numbers were metered against. Upgrades
        /// re-read current usage against this fixed start; without it the
        /// cleared burst maps would meter lifetime as a delta.
        var baseline: (tokens: Int, cost: Double)?
        var covered: Bool
    }

    /// Last recorded completion per pane. Cleared by progress/started,
    /// pruned with the other per-pane maps.
    private var completionMarks: [String: CompletionMark] = [:]
    /// Latest approval prompt shape per pane, decoded from the event stream
    /// and enriched from the live pane when the event is only "blocked".
    var pendingApprovals: [String: PendingApproval] = [:]
    /// Panes answered from Bantay recently. Status hooks can repeat the same
    /// `blocked` line after the answer lands; suppressing that exact
    /// fingerprint stops the popup from re-asking for a permission the user
    /// just granted. A non-approval status clears the entry, so a genuinely
    /// new prompt still shows immediately.
    private var acknowledgedApprovalFingerprints: [String: Set<String>] = [:]
    private var approvalEnrichmentTasks: [String: Task<Void, Never>] = [:]
    /// Last pane capture per approval. Repeated `blocked` heartbeats must not
    /// spawn a fresh terminal read on every roster refresh.
    private var lastApprovalCaptureAt: [String: Date] = [:]
    /// Panes with an in-flight user action to prevent duplicate clicks.
    private var resolvingPanes: Set<String> = []
    /// Caps how long a pane stays in the resolving state if the next poll
    /// doesn't clear it (e.g. herdr daemon down).
    private let resolvingTimeout: TimeInterval = 4
    private let eventsFileURL: URL
    private let captureEnabled: Bool
    private let herdrAdapter = HerdrSocketAdapter()
    var activeAdapter: any PlexerAdapter = PlexerFactory.makeAdapter()
    /// Append-only decision receipts. Injected in tests; shared in the app.
    private let receiptStore: ApprovalReceiptStore
    /// Session history. Injected in tests; shared in the app.
    private let sessionStore: SessionHistoryStore

    init(
        eventsFileURL: URL? = nil, capture: Bool = true,
        receiptStore: ApprovalReceiptStore? = nil,
        sessionStore: SessionHistoryStore? = nil
    ) {
        self.captureEnabled = capture
        self.receiptStore = receiptStore ?? .shared
        self.sessionStore = sessionStore ?? .shared
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
                guard let self else { return }
                AwayDigestStore.shared.beginAway(
                    baselineCost: self.usage.costUSD,
                    baselineTokens: self.usage.totalTokens
                )
            }
        }
        wakeObserver = workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayAsleep = false
                guard let self else { return }
                if AwayDigestStore.shared.isAway {
                    let pending = self.agents.filter {
                        $0.kind == .accessRequest || $0.kind == .waiting
                    }.count
                    AwayDigestStore.shared.endAway(
                        currentCost: self.usage.costUSD,
                        currentTokens: self.usage.totalTokens,
                        pendingApprovals: pending
                    )
                }
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
                guard let self else { return }
                AwayDigestStore.shared.beginAway(
                    baselineCost: self.usage.costUSD,
                    baselineTokens: self.usage.totalTokens
                )
            }
        }
        unlockObserver = distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayLocked = false
                guard let self else { return }
                let pending = self.agents.filter {
                    $0.kind == .accessRequest || $0.kind == .waiting
                }.count
                AwayDigestStore.shared.endAway(
                    currentCost: self.usage.costUSD,
                    currentTokens: self.usage.totalTokens,
                    pendingApprovals: pending
                )
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
        let text = String(decoding: data, as: UTF8.self)
        lineBuffer += text
        readOffset = end

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
        if event.kind != .accessRequest && event.kind != .waiting {
            clearAcknowledgments(for: event)
        } else if isAcknowledged(event) {
            return
        }
        let key = event.identityKey
        let actionablePaneId = IslandMetrics.actionablePaneId(
            paneId: event.paneId, source: event.source)
        // ntfy.sh push for events that need attention even away from the
        // terminal: approvals/blocked always; failures and completions too.
        if let source = event.source {
            let snap = self.agents.first {
                (event.paneId != nil && $0.paneId == event.paneId)
                    || $0.source == source
            }
            AgentAlertNotifier.notify(
                source: source,
                kind: event.kind,
                title: event.title ?? event.message,
                paneId: actionablePaneId,
                choices: event.choices,
                cwd: snap?.cwd,
                sessionPath: snap?.sessionPath,
                roster: self.agents,
                isMulti: event.variance == .multi
            )
            MultiAgentTimelineStore.shared.recordEvent(
                agentName: source,
                project: snap?.cwd.flatMap { ($0 as NSString).lastPathComponent },
                kind: event.kind,
                title: event.title ?? event.message ?? event.kind.label,
                now: event.createdAt
            )
        }
        TaskStore.shared.updateTaskState(
            paneId: event.paneId, source: event.sourceKey, kind: event.kind)
        if event.kind == .accessRequest || event.kind == .waiting {
            let prompt = ApprovalPromptResolver.resolve(
                rawTail: "",
                fallbackTitle: event.title,
                fallbackMessage: event.message,
                fallbackVariance: event.variance == .yesNo ? .yesNo : nil,
                kind: event.kind)
            let explicitChoices = (event.choices ?? []).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            // Transport gate: panes that cannot receive a decision stay
            // review-only no matter how concrete the parsed prompt looks.
            let supportsTransport = supportsDecision(
                paneId: actionablePaneId ?? key)
            let actionable =
                (prompt.actionable
                    || (event.kind == .accessRequest && explicitChoices.count >= 2))
                && supportsTransport
            let variance: ApprovalVariance? =
                prompt.variance
                ?? (explicitChoices.count >= 2 ? .choices : event.variance)
            let pending = PendingApproval(
                eventID: event.id,
                title: prompt.detail ?? event.title,
                message: prompt.detail == nil ? event.message : nil,
                variance: variance,
                choices: prompt.choices.isEmpty ? event.choices : prompt.choices,
                choiceDetails: prompt.choiceDetails.isEmpty ? nil : prompt.choiceDetails,
                actionable: actionable,
                risk: prompt.risk,
                prompt: prompt)
            pendingApprovals[key] = pending
            if pending.needsEnrichment {
                enrichApproval(event: event, key: key, paneId: actionablePaneId)
            }
        } else if event.kind != .progress && event.kind != .started {
            pendingApprovals.removeValue(forKey: key)
            approvalEnrichmentTasks[key]?.cancel()
            approvalEnrichmentTasks.removeValue(forKey: key)
            lastApprovalCaptureAt.removeValue(forKey: key)
            // The pane stopped blocking: drop any pending notification so a
            // stale Approve/Deny can't inject a keypress into the pane now.
            if event.paneId != nil || event.source != nil {
                let paneKey = actionablePaneId ?? event.paneId ?? event.source ?? key
                ApprovalNotificationController.shared.removeForPane(paneKey)
            }
        }
        var completionDuration: TimeInterval?
        let sessionStart = startedAtByPane[key] ?? event.createdAt
        // True when this event recorded a fresh session row (not a dupe
        // heartbeat). Gates recents + digest below on the same rule.
        var recordedFreshFinish = false
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
            if usageBaselineByKey[key] == nil {
                usageBaselineByKey[key] = (
                    tokens: lifetimeAccrual.tokensBySource[event.sourceKey] ?? 0,
                    cost: lifetimeAccrual.costBySource[event.sourceKey] ?? 0
                )
                baselineCoveredByKey[key] = lifetimeAccrual.covered.contains(
                    event.sourceKey)
            }
            // New working burst re-arms completion recording: the next
            // completion for this pane is a real finish, not a heartbeat.
            completionMarks.removeValue(forKey: key)
        } else if event.kind == .completed || event.kind == .failed
            || event.kind == .cancelled || event.kind == .clear
        {
            startedAtByPane.removeValue(forKey: key)
        }

        if event.kind == .completed || event.kind == .failed {
            let snap = self.agents.first {
                (event.paneId != nil && $0.paneId == event.paneId)
                    || $0.source == event.sourceKey
            }
            let sessionIdentity = snap?.sessionPath.flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
            // Prefer the roster's terminal title over a bare kind label:
            // completion events often carry no text, and the terminal title
            // names the actual task. It also unifies the titles of refires
            // so the dedupe below sees one finish, not two.
            let title = event.title ?? event.message ?? snap?.title ?? event.kind.label
            // One finish often arrives as several events with different
            // titles. The session path identifies the finish; without one,
            // the title does. Identical refires skip without recomputing;
            // cross-title refires re-meter against the recorded baseline
            // and keep the most complete numbers.
            let fingerprint = "\(event.kind.rawValue):\(sessionIdentity ?? title)"
            let marked = completionMarks[key]
            if marked?.fingerprint == fingerprint, marked?.title == title {
                // Identical refire: nothing new. Skip the recompute too —
                // the ledger scan behind it is seconds of main-thread disk.
            } else {
                let upgrading = marked?.fingerprint == fingerprint
                if upgrading, marked?.baseline == nil {
                    // Same finish, still no observable start (progress
                    // would have cleared the mark): keep waiting, keep mark.
                } else {
                    let metered = meterCompletion(
                        key: key, sourceKey: event.sourceKey,
                        sessionStart: sessionStart,
                        fixedBaseline: upgrading
                            ? marked.flatMap({ $0.baseline }) : nil,
                        fixedCovered: upgrading ? marked?.covered : nil)
                    if !upgrading || metered.tokens > (marked?.tokens ?? -1) {
                        let failed = event.kind == .failed
                        // A finished session with no attributable usage is
                        // not a session row: without a baseline the numbers
                        // would be lifetime totals, and zeros carry no
                        // information. Failures keep their error signal
                        // with honest zero numbers.
                        let attributable =
                            metered.baseline != nil
                            && !(metered.tokens == 0 && metered.cost <= 0)
                        if !failed, !attributable {
                            completionMarks[key] = CompletionMark(
                                fingerprint: fingerprint, title: title,
                                tokens: 0, rowId: "",
                                baseline: metered.baseline,
                                covered: metered.covered)
                        } else {
                            let rowId = "\(key):\(Int(event.createdAt.timeIntervalSince1970))"
                            let resolvedTitle: String
                            if let old = marked.flatMap({
                                sessionStore.session(withId: $0.rowId)
                            }),
                                old.title != event.kind.label
                            {
                                resolvedTitle = old.title
                            } else {
                                resolvedTitle = title
                            }
                            if upgrading, !(marked?.rowId.isEmpty ?? true) {
                                sessionStore.updateSessionNumbers(
                                    id: marked!.rowId, tokens: metered.tokens,
                                    cost: metered.cost,
                                    duration: completionDuration ?? 0,
                                    title: resolvedTitle)
                            } else {
                                sessionStore.addSession(
                                    AgentSessionRecord(
                                        id: rowId,
                                        agentName: event.sourceKey,
                                        title: resolvedTitle,
                                        startTime: sessionStart,
                                        durationSeconds: completionDuration ?? 0,
                                        totalTokens: metered.tokens,
                                        costUSD: metered.cost,
                                        status: failed ? "Failed" : "Completed",
                                        project: snap?.projectContext?.project
                                            ?? snap?.cwd.flatMap {
                                                ($0 as NSString).lastPathComponent
                                            },
                                        branch: snap?.projectContext?.branch,
                                        sessionPath: snap?.sessionPath,
                                        cwd: snap?.cwd,
                                        isDelta: metered.covered
                                            && metered.baseline != nil,
                                        isWindowEstimate: !metered.covered
                                            && metered.baseline != nil,
                                        buildTag: SessionHistoryStore
                                            .currentBuildTag))
                                recordedFreshFinish = true
                            }
                            completionMarks[key] = CompletionMark(
                                fingerprint: fingerprint, title: title,
                                tokens: metered.tokens, rowId: rowId,
                                baseline: metered.baseline,
                                covered: metered.covered)
                        }
                    }
                }
            }
            usageBaselineByKey.removeValue(forKey: key)
            baselineCoveredByKey.removeValue(forKey: key)
        }
        // Recents and the away digest follow the same dupe rule: a repeated
        // heartbeat must not push the same finish five times.
        if (event.kind == .completed || event.kind == .failed) && !isActive
            && recordedFreshFinish
        {
            let recent = RecentCompletion(
                id: "\(key):\(event.kind.rawValue):\(event.createdAt.timeIntervalSince1970)",
                source: event.sourceKey,
                kind: event.kind,
                title: event.title ?? event.message,
                createdAt: event.createdAt,
                duration: completionDuration)
            recentCompletions = Array(([recent] + recentCompletions).prefix(5))
            if event.kind == .completed {
                AwayDigestStore.shared.recordCompletion(recent)
            } else {
                AwayDigestStore.shared.recordFailure(
                    agent: event.sourceKey,
                    reason: event.title ?? event.message
                )
            }
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

    /// Agent-aware status mapping. Pi has no built-in permission system — a
    /// `blocked` status is an extension/trust dialog, not a request Bantay can
    /// approve. Surface it as amber `.waiting` instead of a red "Need
    /// approval" alarm (which implies an approvable security decision).
    nonisolated static func kind(for status: String, agent: String) -> AgentEventKind? {
        guard let kind = kind(for: status) else { return nil }
        if agent == "pi", kind == .accessRequest { return .waiting }
        return kind
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
        guard let kind = kind(for: agent.agentStatus ?? "", agent: agent.agent) else { return nil }
        let projectContext: ProjectContext? = {
            guard let cwd = agent.cwd, !cwd.isEmpty else { return nil }
            return ProjectContext.cachedOrPlaceholder(cwd: cwd)
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
            projectContext: projectContext,
            sessionPath: agent.agentSession?.value
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
            guard let kind = kind(for: agent.agentStatus ?? "", agent: agent.agent),
                kind != .idle
            else { continue }
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
                    try? await Task.sleep(for: .seconds(5))
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
        if isRefreshingRoster { return }
        isRefreshingRoster = true
        // Do not chain a queued refresh here. If a scan outlasts the poll
        // interval, chaining keeps the scan loop back-to-back forever. The
        // capture loop's next tick picks the work up instead.
        defer { isRefreshingRoster = false }
        ensureFileWatcher()
        let herdrAgents: [HerdrAgentInfo] = await herdrAdapter.listAgents()
        let scanStandalone = NotchHUDConfig.shared.standaloneScanEnabled
        // Heavy scans (ps, transcript enumeration) run off the main actor so
        // the island never beachballs while polling. PERF-2: throttle the ps
        // spawn to `minScanInterval` — the roster is fine updating every few
        // seconds without re-scanning the process table each time.
        let scanInterval: TimeInterval =
            lastDetectedAgents.contains(where: { $0.isWorking })
            ? Self.minScanInterval : Self.idleScanInterval
        let rescan =
            scanStandalone
            && StandaloneAgentScanner.shouldRescan(
                lastScan: lastStandaloneScan, now: Date(),
                minInterval: scanInterval)
        if rescan {
            lastStandaloneScan = Date()
            if let existing = activeScanTask {
                lastDetectedAgents = await existing.value
            } else {
                let task = Task.detached(priority: .userInitiated) {
                    StandaloneAgentScanner.scan()
                }
                activeScanTask = task
                lastDetectedAgents = await task.value
                activeScanTask = nil
            }
        }
        let currentDetected = scanStandalone ? lastDetectedAgents : []
        let agents: [HerdrAgentInfo] = await Task.detached(priority: .userInitiated) {
            return herdrAgents
                + currentDetected.filter { detected in
                    !herdrAgents.contains { herdr in
                        herdr.agent == detected.name
                            && (herdr.cwd == nil || herdr.cwd == detected.cwd)
                    }
                }.map { detected in
                    let projectSlug: String = {
                        if let cwd = detected.cwd, !cwd.isEmpty {
                            return URL(fileURLWithPath: cwd).lastPathComponent
                        }
                        if let session = detected.sessionPath, !session.isEmpty {
                            return URL(fileURLWithPath: session).lastPathComponent
                        }
                        return "standalone"
                    }()
                    let sessionRef: HerdrAgentSession? = {
                        if let session = detected.sessionPath, !session.isEmpty {
                            return HerdrAgentSession(
                                agent: detected.name, kind: "path", value: session)
                        }
                        return nil
                    }()
                    return HerdrAgentInfo(
                        agent: detected.name,
                        agentStatus: detected.isWorking ? "working" : "idle",
                        paneId: "standalone:\(detected.name):\(projectSlug)",
                        workspaceId: nil,
                        terminalTitle: detected.activity,
                        cwd: detected.cwd,
                        agentSession: sessionRef
                    )
                }
        }.value
        // Transcript token/cost enumeration is gated behind `usageTrackingEnabled`.
        // Usage sweeps read transcripts. Run them on a calmer cadence than
        // the roster poll: 15s while agents are live, 120s when idle. The
        // header is the only consumer, so a slower gauge is not felt.
        let usageNow = Date()
        let usageInterval: TimeInterval = agents.isEmpty ? 120 : 15
        if NotchHUDConfig.shared.usageTrackingEnabled,
            usageNow.timeIntervalSince(lastUsagePollAt) >= usageInterval
        {
            lastUsagePollAt = usageNow
            let hasKilo = agents.contains { $0.agent == "kilo" }
            let now = usageNow
            if hasKilo, KiloUsageAdapter.detect() {
                // Read Kilo usage from SQLite off-main.
                let pollInterval = NotchHUDConfig.shared.captureInterval
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
                    return (usage, rate, window)
                }.value
                if self.usage != result.0 { self.usage = result.0 }
                if self.usageRate != result.1 { self.usageRate = result.1 }
                self.lastKiloSnapshot = result.2
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
                if self.usage != usageAndRate.0 { self.usage = usageAndRate.0 }
                if self.usageRate != usageAndRate.1 { self.usageRate = usageAndRate.1 }
                // Lifetime counters for session deltas. Transcript files
                // accrue incrementally (appended bytes only); the opencode
                // ledger refreshes from its monotonic sums on file change.
                let nowLifetime = Date()
                if nowLifetime.timeIntervalSince(self.lastLifetimeAccrualAt)
                    >= self.lifetimeAccrualInterval
                {
                    self.lastLifetimeAccrualAt = nowLifetime
                    let prior = self.lifetimeAccrual
                    let names = agents.map { $0.agent }
                    self.lifetimeAccrual = await Task.detached(priority: .utility) {
                        UsageTracker.accrueLifetime(
                            home: NSHomeDirectory(), names: names, state: prior)
                    }.value
                }
                let revision = OpenCodeUsageAdapter.ledgerRevision(
                    home: NSHomeDirectory())
                if revision != self.lifetimeOpencodeRevision {
                    self.lifetimeOpencodeRevision = revision
                    let lifetimeNow = now
                    let life = await Task.detached(priority: .utility) {
                        OpenCodeUsageAdapter.snapshot(
                            since: 30 * 365 * 86400, now: lifetimeNow,
                            home: NSHomeDirectory())
                    }.value
                    if let life {
                        self.lifetimeAccrual.tokensBySource["opencode"] =
                            life.tokensBySource["opencode"] ?? 0
                        self.lifetimeAccrual.costBySource["opencode"] =
                            life.costBySource["opencode"] ?? 0
                        self.lifetimeAccrual.covered.insert("opencode")
                    }
                }
            }
            SpendHistoryStore.shared.recordUsage(
                snapshot: self.usage,
                peakTPM: self.usageRate.tokensPerMinute ?? 0.0
            )
            evaluateBudgetAndQuotaAlerts()
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
        for agent in agents where agent.agentStatus == "working" {
            let key = agent.paneId ?? agent.agent
            if startedAtByPane[key] == nil {
                startedAtByPane[key] = Date()
            }
        }
        let liveAgentKeys = Set(agents.compactMap { $0.paneId ?? $0.agent })
        startedAtByPane = startedAtByPane.filter { liveAgentKeys.contains($0.key) }
        usageBaselineByKey = usageBaselineByKey.filter { liveAgentKeys.contains($0.key) }
        baselineCoveredByKey = baselineCoveredByKey.filter {
            liveAgentKeys.contains($0.key)
        }
        completionMarks = completionMarks.filter {
            liveAgentKeys.contains($0.key)
        }
        // Tasks stuck in flight on dead panes can never transition again.
        // Reset them to pending while the live roster is in hand.
        TaskStore.shared.resetOrphanedTasks(
            livePaneIDs: Set(agents.compactMap { $0.paneId }))
        let mergedRoster = mergeApprovals(into: result.roster)
        if self.agents != mergedRoster {
            self.agents = mergedRoster
        }
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
        let mergedRoster = mergeApprovals(into: result.roster)
        if self.agents != mergedRoster {
            self.agents = mergedRoster
        }
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
        return roster.compactMap { (agent: AgentSnapshot) -> AgentSnapshot? in
            guard !muted.contains(agent.source) else { return nil }
            let key = agent.paneId ?? agent.source
            var title = agent.title
            var message = agent.message
            var variance = agent.variance
            var choices = agent.choices
            var choiceDetails = agent.choiceDetails
            var actionable = agent.approvalActionable
            var risk = agent.approvalRisk
            if agent.kind == .accessRequest || agent.kind == .waiting,
                let pending = pendingApprovals[key]
            {
                title = pending.title ?? title
                message = pending.message ?? message
                variance = pending.variance ?? variance
                choices = pending.choices ?? choices
                choiceDetails = pending.choiceDetails ?? choiceDetails
                // The roster re-checks transport: a pane that lost its route
                // (input synthesis disabled mid-session) drops to review-only.
                actionable =
                    pending.actionable
                    && supportsDecision(paneId: agent.paneId ?? agent.source)
                risk = pending.risk
            }
            let startedAt = startedAtByPane[key]
            return AgentSnapshot(
                id: agent.id,
                source: agent.source,
                kind: agent.kind,
                title: title,
                message: message,
                paneId: agent.paneId,
                workspaceId: agent.workspaceId,
                cwd: agent.cwd,
                variance: variance,
                choices: choices,
                choiceDetails: choiceDetails,
                startedAt: startedAt,
                projectContext: agent.projectContext,
                sessionPath: agent.sessionPath,
                approvalActionable: actionable,
                approvalRisk: risk
            )
        }
    }

    /// Capture the live pane or transcript when a blocked event carries only
    /// a status. Runs off the main thread; the card renders Review-only until
    /// the exact request and choices arrive.
    private func enrichApproval(event: AgentEvent, key: String, paneId: String?) {
        guard approvalEnrichmentTasks[key] == nil else { return }
        let now = Date()
        if let last = lastApprovalCaptureAt[key],
            now.timeIntervalSince(last) < 5
        {
            return
        }
        lastApprovalCaptureAt[key] = now
        let adapter = activeAdapter
        let source = event.sourceKey
        let eventID = event.id
        let fallbackTitle = event.title
        let fallbackMessage = event.message
        let fallbackVariance = event.variance == .yesNo ? ApprovalVariance.yesNo : nil
        let kind = event.kind
        let agent = agents.first {
            ($0.paneId != nil && $0.paneId == paneId)
                || $0.source == source
        }
        let sessionPath = agent?.sessionPath
        let cwd = agent?.cwd
        approvalEnrichmentTasks[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            var raw = ""
            if let paneId, !paneId.hasPrefix("standalone:") {
                raw = await adapter.captureTail(paneId: paneId, lines: 30)
            }
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                raw = AgentDetector.recentTranscriptOutput(
                    forAgent: source,
                    sessionPath: sessionPath,
                    cwd: cwd,
                    maxLines: 30
                ).joined(separator: "\n")
            }
            let prompt = ApprovalPromptResolver.resolve(
                rawTail: raw,
                fallbackTitle: fallbackTitle,
                fallbackMessage: fallbackMessage,
                fallbackVariance: fallbackVariance,
                kind: kind)
            defer { self.approvalEnrichmentTasks[key] = nil }
            guard let current = self.pendingApprovals[key],
                current.eventID == eventID
            else { return }
            self.pendingApprovals[key] = PendingApproval(
                eventID: eventID,
                title: prompt.detail ?? current.title,
                message: prompt.detail == nil ? current.message : nil,
                variance: prompt.variance ?? current.variance,
                choices: prompt.choices.isEmpty ? current.choices : prompt.choices,
                choiceDetails: prompt.choiceDetails.isEmpty
                    ? current.choiceDetails : prompt.choiceDetails,
                actionable: (prompt.actionable
                    || (kind == .accessRequest
                        && (prompt.choices.count >= 2
                            || (current.choices?.count ?? 0) >= 2)))
                    && self.supportsDecision(paneId: paneId ?? key),
                risk: prompt.risk,
                prompt: prompt)
            self.agents = self.mergeApprovals(into: self.agents)
        }
    }

    /// True while an action is in flight for `paneId` — the control plane
    /// disables its buttons and shows a resolving state to prevent re-fire.
    func isResolving(paneId: String) -> Bool {
        resolvingPanes.contains(paneId)
    }

    /// Convenience: resolves the agent's actionable pane id (including the
    /// synthetic id used for standalone agents) and checks `isResolving`.
    func isResolving(agent: AgentSnapshot?) -> Bool {
        guard
            let paneId = IslandMetrics.actionablePaneId(
                paneId: agent?.paneId, source: agent?.source)
        else { return false }
        return resolvingPanes.contains(paneId)
    }

    /// Fire an adapter action off the main actor (the adapter does blocking
    /// `Process.waitUntilExit` I/O) and optimistically mark the pane as
    /// resolving so the UI can't double-fire and feels instant. The resolving
    /// flag clears on the next confirming poll, or after `resolvingTimeout`.
    func performAction(
        paneId: String, _ action: @escaping @Sendable (any PlexerAdapter) -> Void
    ) {
        resolvingPanes.insert(paneId)
        let adapter = activeAdapter
        Task.detached {
            action(adapter)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(self.resolvingTimeout))
                self.resolvingPanes.remove(paneId)
            }
        }
    }

    /// Historical names for the approval-proof outcome types. `ActionResult`
    /// is `.sent` (the transport accepted the write) or `.failed` with the
    /// exact reason. `.sent` is never an agent acknowledgment.
    typealias ActionFailure = ApprovalFailure
    typealias ActionResult = ApprovalOutcome

    /// Whether the inbox may offer a decision for `paneId`. Pure transport
    /// capability: external event channels and disabled input synthesis stay
    /// review-only even before liveness is known.
    func supportsDecision(paneId: String) -> Bool {
        ApprovalRouting.supportsDecision(
            paneId: paneId,
            inputSynthesisEnabled: StandaloneAgentDispatcher.enableInputSynthesis)
    }

    /// Why `paneId` is review-only, if it is.
    func observeReason(paneId: String) -> ApprovalObserveReason? {
        if case .observeOnly(let reason) = ApprovalRouting.route(
            paneId: paneId,
            adapterKind: activeAdapter.kind,
            inputSynthesisEnabled: StandaloneAgentDispatcher.enableInputSynthesis,
            paneAlive: paneIsAlive(paneId))
        {
            return reason
        }
        return nil
    }

    /// Metered usage for a finished burst: current counters minus the burst
    /// baseline. Ledger-metered sources use the as-of-start ledger read so
    /// short sessions cannot meter ~0; everything else uses the in-memory
    /// burst baseline captured on progress. A nil baseline means no start
    /// was ever observed: the numbers are unattributable.
    private struct MeteredCompletion: Sendable {
        var tokens: Int
        var cost: Double
        var baseline: (tokens: Int, cost: Double)?
        var covered: Bool
    }

    private func meterCompletion(
        key: String, sourceKey: String, sessionStart: Date,
        fixedBaseline: (tokens: Int, cost: Double)? = nil,
        fixedCovered: Bool? = nil
    ) -> MeteredCompletion {
        // The periodic lifetime sweep may be up to 10s behind. A finish is
        // the one moment the final tokens must land, so accrue transcript
        // sources once more before metering.
        if !UsageTracker.ledgerCoveredSources.contains(sourceKey) {
            lifetimeAccrual = UsageTracker.accrueLifetime(
                home: NSHomeDirectory(),
                names: self.agents.map { $0.source },
                state: lifetimeAccrual)
        }
        // Ledger-metered sources skip in-memory baselines entirely: the
        // ledger answers "as of session start" exactly, so short sessions
        // cannot meter ~0.
        let ledgerBaseline: (tokens: Int, cost: Double)? =
            UsageTracker.ledgerCoveredSources.contains(sourceKey)
                && OpenCodeUsageAdapter.detect()
            ? OpenCodeUsageAdapter.meterAsOf(
                beforeMs: Int64(sessionStart.timeIntervalSince1970 * 1000))
            : nil
        let ledgerCurrent: UsageSnapshot? =
            ledgerBaseline == nil
            ? nil
            : OpenCodeUsageAdapter.snapshot(since: 30 * 365 * 86400, maxAge: 0)
        var baseline = fixedBaseline ?? usageBaselineByKey[key]
        var covered =
            fixedCovered ?? baselineCoveredByKey[key]
            ?? lifetimeAccrual.covered.contains(sourceKey)
        var currentTokens =
            covered
            ? (lifetimeAccrual.tokensBySource[sourceKey] ?? 0)
            : (usage.tokensBySource[sourceKey] ?? 0)
        var currentCost =
            covered
            ? (lifetimeAccrual.costBySource[sourceKey] ?? 0)
            : (usage.costBySource[sourceKey] ?? 0)
        if fixedBaseline != nil {
            // Upgrade path: the baseline is pinned to record time (the
            // burst maps were cleared), but current usage re-reads live.
            // Counters and the ledger only grow, so the upgrade can only
            // complete the numbers, never shrink them.
            if UsageTracker.ledgerCoveredSources.contains(sourceKey),
                OpenCodeUsageAdapter.detect(),
                let snap = OpenCodeUsageAdapter.snapshot(
                    since: 30 * 365 * 86400, maxAge: 0)
            {
                currentTokens = snap.totalTokens
                currentCost = snap.costUSD
            }
        } else if let ledgerBaseline, let ledgerCurrent {
            baseline = ledgerBaseline
            covered = true
            currentTokens = ledgerCurrent.totalTokens
            currentCost = ledgerCurrent.costUSD
        }
        // Covered sources meter against monotonic lifetime counters.
        // Uncovered sources fall back to the rolling window — an honest
        // estimate, labeled as one downstream.
        return MeteredCompletion(
            tokens: SessionUsageDelta.tokens(
                current: currentTokens, baseline: baseline?.tokens ?? 0),
            cost: SessionUsageDelta.cost(
                current: currentCost, baseline: baseline?.cost ?? 0),
            baseline: baseline,
            covered: covered)
    }

    /// A user decision that needs a transport write.
    private enum DecisionKind: Sendable {
        case approve
        case deny
        case choice(Int)
        case multi([Int])
        case reply(String)

        var actionName: String {
            switch self {
            case .approve: return "approve"
            case .deny: return "deny"
            case .choice: return "choice"
            case .multi: return "multi"
            case .reply: return "reply"
            }
        }

        var detail: String {
            switch self {
            case .approve: return "approve"
            case .deny: return "deny"
            case .choice(let number): return String(number)
            case .multi(let selections):
                return selections.map(String.init).joined(separator: ",")
            case .reply(let text): return text
            }
        }
    }

    /// Single decision pipeline: route, await the transport, record a
    /// receipt, and only then acknowledge. A failure keeps the request
    /// visible and returns the exact reason; it never reports success.
    private func decide(paneId: String, decision: DecisionKind) async -> ApprovalOutcome {
        let target = paneId.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .reply(let text) = decision,
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .failed(.emptyText)
        }
        let route = ApprovalRouting.route(
            paneId: target,
            adapterKind: activeAdapter.kind,
            inputSynthesisEnabled: StandaloneAgentDispatcher.enableInputSynthesis,
            paneAlive: paneIsAlive(target))
        guard route.canRespond else {
            let reason: ApprovalObserveReason
            if case .observeOnly(let gated) = route {
                reason = gated
            } else {
                reason = .paneUnavailable
            }
            // A dead pane is a lookup miss, not a decision: no receipt.
            if reason != .paneUnavailable {
                recordDecision(
                    paneId: target, decision: decision, route: route,
                    outcome: .failed(reason.failure))
            }
            return .failed(reason.failure)
        }
        resolvingPanes.insert(target)
        let outcome: ApprovalOutcome
        switch route {
        case .openCodeDecisionFile:
            outcome = writeOpenCodeDecision(paneId: target, decision: decision)
        case .standalone:
            outcome = standaloneDecision(paneId: target, decision: decision)
        case .multiplexer:
            outcome = await adapterDecision(paneId: target, decision: decision)
        case .observeOnly:
            outcome = .failed(.unsupported)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(self.resolvingTimeout))
            self.resolvingPanes.remove(target)
        }
        recordDecision(
            paneId: target, decision: decision, route: route, outcome: outcome)
        if outcome.isSent {
            AwayDigestStore.shared.recordApprovalAnswered()
            acknowledgeApproval(paneId: target)
        }
        return outcome
    }

    /// OpenCode decisions travel through the plugin's decision file. The
    /// writer's Bool is the transport proof: a failed write is `.failed`.
    private func writeOpenCodeDecision(
        paneId: String, decision: DecisionKind
    ) -> ApprovalOutcome {
        switch decision {
        case .approve:
            return OpenCodeActionWriter.writeDecision(paneId: paneId, approve: true)
                ? .sent : .failed(.transport)
        case .deny:
            return OpenCodeActionWriter.writeDecision(paneId: paneId, approve: false)
                ? .sent : .failed(.transport)
        case .choice(let number):
            return OpenCodeActionWriter.writeDecision(
                paneId: paneId, approve: true, choiceIndex: number)
                ? .sent : .failed(.transport)
        case .multi:
            return OpenCodeActionWriter.writeDecision(paneId: paneId, approve: true)
                ? .sent : .failed(.transport)
        case .reply(let text):
            // Free text still travels through input synthesis (existing
            // behavior); only the failure mapping is new.
            guard StandaloneAgentDispatcher.enableInputSynthesis else {
                return .failed(.inputSynthesisDisabled)
            }
            let agent = agent(forPaneId: paneId)
            let ok = StandaloneAgentDispatcher.dispatchPrompt(
                agentName: "opencode", text: text, cwd: agent?.cwd, autoSend: true)
            return promptOutcome(ok: ok)
        }
    }

    /// Standalone decisions focus the target app and schedule one keystroke.
    /// `.sent` means focus succeeded and the keystroke was scheduled with
    /// Accessibility granted. Anything else maps to its exact failure.
    private func standaloneDecision(
        paneId: String, decision: DecisionKind
    ) -> ApprovalOutcome {
        guard StandaloneAgentDispatcher.enableInputSynthesis else {
            return .failed(.inputSynthesisDisabled)
        }
        guard StandaloneAgentDispatcher.accessibilityGranted() else {
            return .failed(.accessibility)
        }
        let agent = agent(forPaneId: paneId)
        let name = StandaloneAgentDispatcher.cleanAgentName(from: paneId)
        let target = name.isEmpty ? (agent?.source ?? paneId) : name
        let ok: Bool
        switch decision {
        case .approve:
            ok = StandaloneAgentDispatcher.dispatchApproval(
                agentName: target, approved: true, cwd: agent?.cwd)
        case .deny:
            ok = StandaloneAgentDispatcher.dispatchApproval(
                agentName: target, approved: false, cwd: agent?.cwd)
        case .choice(let number):
            ok = StandaloneAgentDispatcher.dispatchOption(
                agentName: target, option: String(number), cwd: agent?.cwd)
        case .multi(let selections):
            ok = StandaloneAgentDispatcher.dispatchOption(
                agentName: target,
                option: selections.map(String.init).joined(separator: " "),
                cwd: agent?.cwd)
        case .reply(let text):
            ok = StandaloneAgentDispatcher.dispatchPrompt(
                agentName: target, text: text, cwd: agent?.cwd, autoSend: true)
        }
        return ok ? .sent : .failed(.targetUnavailable)
    }

    /// Multiplexer decisions await the confirmed send. False is always
    /// `.transport`: the process exit or socket call is the only proof.
    private func adapterDecision(
        paneId: String, decision: DecisionKind
    ) async -> ApprovalOutcome {
        let adapter = activeAdapter
        // OpenCode's question form treats a digit as a hotkey: it picks a
        // single option immediately and toggles a multi-select row without
        // submitting. Enter toggles the focused row, so multi-select needs
        // Tab (to the Submit control) before Enter.
        let isOpenCodeForm = agent(forPaneId: paneId)?.source.lowercased() == "opencode"
        var ok: Bool
        switch decision {
        case .approve:
            ok = await adapter.sendKeysConfirmed(paneId: paneId, keys: ["y", "enter"])
        case .deny:
            ok = await adapter.sendKeysConfirmed(paneId: paneId, keys: ["n", "enter"])
        case .choice(let number):
            if isOpenCodeForm {
                ok = await adapter.sendKeysConfirmed(
                    paneId: paneId, keys: [String(number)])
            } else {
                ok = await adapter.sendLineConfirmed(paneId: paneId, text: String(number))
            }
        case .multi(let selections):
            if isOpenCodeForm {
                var keys = selections.sorted().map(String.init)
                keys.append("tab")
                keys.append("enter")
                ok = await adapter.sendKeysConfirmed(paneId: paneId, keys: keys)
            } else {
                ok = await adapter.sendLineConfirmed(
                    paneId: paneId, text: selections.map(String.init).joined(separator: ","))
            }
        case .reply(let text):
            // A numbered "Type your own answer" / "Other" row means the form
            // is still in its option list. Typing alone does nothing there:
            // select the custom row first, then write the answer.
            if let custom = pendingApprovals[paneId]?.customChoiceNumber {
                ok = await adapter.sendKeysConfirmed(
                    paneId: paneId, keys: [String(custom)])
                if ok {
                    try? await Task.sleep(for: .milliseconds(200))
                    ok = await adapter.sendLineConfirmed(paneId: paneId, text: text)
                }
            } else {
                ok = await adapter.sendLineConfirmed(paneId: paneId, text: text)
                adapter.focusPane(paneId: paneId)
            }
        }
        return ok ? .sent : .failed(.transport)
    }

    /// Maps a prompt-dispatch Bool to its failure: with input synthesis on,
    /// false means the target app is gone; without Accessibility the grant
    /// is the reason.
    private func promptOutcome(ok: Bool) -> ApprovalOutcome {
        guard ok else {
            return StandaloneAgentDispatcher.accessibilityGranted()
                ? .failed(.targetUnavailable) : .failed(.accessibility)
        }
        return .sent
    }

    /// Appends the decision receipt. The request text is hashed, not stored.
    private func recordDecision(
        paneId: String, decision: DecisionKind, route: ApprovalRoute,
        outcome: ApprovalOutcome
    ) {
        let fingerprint =
            pendingApprovals[paneId]?.fingerprint
            ?? currentEventFingerprint(for: paneId)
            ?? paneId
        let choice: Int?
        let selections: [Int]?
        switch decision {
        case .choice(let number):
            choice = number
            selections = nil
        case .multi(let picked):
            choice = nil
            selections = picked
        default:
            choice = nil
            selections = nil
        }
        let failure: String?
        if case .failed(let gated) = outcome {
            failure = gated.rawValue
        } else {
            failure = nil
        }
        receiptStore.append(
            ApprovalReceipt(
                paneId: paneId,
                source: agent(forPaneId: paneId)?.source,
                eventKind: eventKind(for: paneId),
                action: decision.actionName,
                choice: choice,
                selections: selections,
                requestHash: ApprovalReceiptStore.requestHash(fingerprint),
                idempotencyKey: ApprovalReceiptStore.requestHash(
                    [paneId, fingerprint, decision.actionName, decision.detail]
                        .joined(separator: "|")),
                route: route.label,
                outcome: outcome.isSent ? "sent" : "failed",
                failure: failure))
    }

    /// Fingerprint of the visible request for `paneId`, if any.
    private func currentEventFingerprint(for paneId: String) -> String? {
        guard let current = currentEvent, event(current, matches: paneId) else {
            return nil
        }
        return ApprovalPromptResolver.fingerprint(for: current, prompt: nil)
    }

    /// Event kind of the visible request for `paneId`, for the receipt.
    private func eventKind(for paneId: String) -> String {
        if let current = currentEvent, event(current, matches: paneId) {
            return current.kind.rawValue
        }
        return "unknown"
    }

    /// True when a real multiplexer pane is still in the roster.
    func paneIsAlive(_ paneId: String) -> Bool {
        if paneId.hasPrefix("standalone:") || paneId.hasPrefix("app:") { return true }
        return agents.contains { $0.paneId == paneId }
    }

    /// Sends free text into an agent and reports whether it was written.
    /// Only a confirmed write returns `.sent`; the draft stays on failure.
    @discardableResult
    func sendText(paneId: String, text: String) async -> ActionResult {
        await decide(
            paneId: paneId,
            decision: .reply(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Approve with a confirmed transport result so the card can show
    /// failures. The request stays visible until the write is confirmed.
    @discardableResult
    func approve(paneId: String) async -> ActionResult {
        await decide(paneId: paneId, decision: .approve)
    }

    /// Deny with a confirmed transport result.
    @discardableResult
    func deny(paneId: String) async -> ActionResult {
        await decide(paneId: paneId, decision: .deny)
    }

    /// Select a numbered choice with a confirmed transport result.
    @discardableResult
    func approveChoice(paneId: String, choice: Int) async -> ActionResult {
        await decide(paneId: paneId, decision: .choice(choice))
    }

    /// Submit a multi-select answer with a confirmed transport result.
    @discardableResult
    func approveMulti(paneId: String, selections: [Int]) async -> ActionResult {
        await decide(paneId: paneId, decision: .multi(selections))
    }

    /// Record that the user answered `paneId` and drop the visible prompt.
    /// The exact prompt fingerprint stays suppressed until the agent reports
    /// a non-approval status, so a repeated `blocked` heartbeat cannot ask
    /// the same question again after the old time window expired.
    func acknowledgeApproval(paneId: String) {
        var keys = [paneId]
        if paneId.hasPrefix("standalone:") {
            keys.append(String(paneId.dropFirst("standalone:".count)))
        }
        let rawFingerprint = currentEvent.map {
            ApprovalPromptResolver.fingerprint(for: $0, prompt: nil)
        }
        if let current = currentEvent, event(current, matches: paneId) {
            keys.append(current.identityKey)
            currentEvent = nil
            clearTask?.cancel()
        }
        for key in pendingApprovals.keys
        where matches(paneId: paneId, identityKey: key) {
            if let pending = pendingApprovals[key] {
                acknowledgedApprovalFingerprints[key, default: []].insert(
                    pending.fingerprint)
            }
            pendingApprovals.removeValue(forKey: key)
            approvalEnrichmentTasks[key]?.cancel()
            approvalEnrichmentTasks.removeValue(forKey: key)
            lastApprovalCaptureAt.removeValue(forKey: key)
        }
        for key in keys {
            if let rawFingerprint {
                acknowledgedApprovalFingerprints[key, default: []].insert(rawFingerprint)
            }
            // Suppress repeated status-only heartbeats even when the visible
            // event was already cleared from currentEvent.
            acknowledgedApprovalFingerprints[key, default: []].insert("accessRequest|||")
            acknowledgedApprovalFingerprints[key, default: []].insert("waiting|||")
        }
        ApprovalNotificationController.shared.removeForPane(paneId)
    }

    private func event(_ event: AgentEvent, matches paneId: String) -> Bool {
        if let id = event.paneId { return id == paneId }
        return matches(paneId: paneId, identityKey: event.identityKey)
    }

    private func matches(paneId: String, identityKey key: String) -> Bool {
        if key == paneId { return true }
        guard paneId.hasPrefix("standalone:") else { return false }
        let source = String(paneId.dropFirst("standalone:".count))
        return key == source || key.hasPrefix(source + ":")
    }

    private func acknowledgmentKeys(for event: AgentEvent) -> [String] {
        var keys = [event.identityKey]
        if let actionable = IslandMetrics.actionablePaneId(
            paneId: event.paneId, source: event.source)
        {
            keys.append(actionable)
        }
        if let source = event.source {
            keys.append(source)
        }
        return keys
    }

    private func isAcknowledged(_ event: AgentEvent) -> Bool {
        let fingerprint = ApprovalPromptResolver.fingerprint(for: event, prompt: nil)
        for key in acknowledgmentKeys(for: event) {
            if acknowledgedApprovalFingerprints[key]?.contains(fingerprint) == true {
                return true
            }
        }
        return false
    }

    private func clearAcknowledgments(for event: AgentEvent) {
        for key in acknowledgmentKeys(for: event) {
            acknowledgedApprovalFingerprints.removeValue(forKey: key)
        }
    }

    /// Routes a stop request to the standalone dispatcher or the multiplexer.
    func stop(paneId: String) {
        if paneId.hasPrefix("standalone:") {
            let agent = agent(forPaneId: paneId)
            let name = StandaloneAgentDispatcher.cleanAgentName(from: paneId)
            performStandaloneAction(paneId: paneId) {
                _ = StandaloneAgentDispatcher.dispatchAbort(
                    agentName: name.isEmpty ? (agent?.source ?? paneId) : name,
                    cwd: agent?.cwd)
            }
            return
        }
        performAction(paneId: paneId) { $0.stop(paneId: paneId) }
    }

    /// The roster entry that owns `paneId`, including synthetic standalone ids.
    func agent(forPaneId paneId: String) -> AgentSnapshot? {
        agents.first { agent in
            if let id = agent.paneId { return id == paneId }
            return paneId == "standalone:\(agent.source)"
                || paneId.hasPrefix("standalone:\(agent.source):")
        }
    }

    /// Keeps the popup buttons disabled while a standalone MainActor action
    /// (stop) runs, mirroring `performAction`'s resolve state.
    private func performStandaloneAction(
        paneId: String, _ action: @escaping @MainActor () -> Void
    ) {
        resolvingPanes.insert(paneId)
        Task { @MainActor in
            action()
            try? await Task.sleep(for: .seconds(self.resolvingTimeout))
            self.resolvingPanes.remove(paneId)
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

    /// Test seam: seed a covered lifetime counter so delta math runs
    /// without polling the real filesystem.
    func setLifetimeCounterForTesting(source: String, tokens: Int, cost: Double) {
        lifetimeAccrual.tokensBySource[source] = tokens
        lifetimeAccrual.costBySource[source] = cost
        lifetimeAccrual.covered.insert(source)
    }

    /// Test seam: inject roster rows without polling a live multiplexer.
    func setAgentsForTesting(_ agents: [AgentSnapshot]) {
        self.agents = agents
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
            approvalEnrichmentTasks[key]?.cancel()
            approvalEnrichmentTasks.removeValue(forKey: key)
            lastApprovalCaptureAt.removeValue(forKey: key)
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
    /// duplicating agents herdr already manages (matched by canonical name and cwd).
    func mergeStandalone(
        into herdr: [HerdrAgentInfo], detected: [DetectedAgent]
    ) -> [HerdrAgentInfo] {
        let extras = detected.filter { det in
            !herdr.contains { h in
                h.agent == det.name && (h.cwd == nil || h.cwd == det.cwd)
            }
        }.map { det in
            let sessionRef = det.sessionPath.map {
                HerdrAgentSession(agent: det.name, kind: "path", value: $0)
            }
            return HerdrAgentInfo(
                agent: det.name,
                agentStatus: det.isWorking ? "working" : "idle",
                paneId: nil,
                workspaceId: nil,
                terminalTitle: det.activity,
                cwd: det.cwd,
                agentSession: sessionRef
            )
        }
        return herdr + extras
    }

    // MARK: - Active Budget & Quota Enforcement (Direction B)

    /// Pure helper to evaluate budget threshold state transitions (testable without side-effects).
    static func evaluateBudgetThreshold(
        cost: Double,
        budget: Double,
        alreadyAlerted80: Bool,
        alreadyAlerted100: Bool
    ) -> (alert80: Bool, alert100: Bool) {
        let safeBudget = max(budget, 0.5)
        let ratio = cost / safeBudget
        var trigger80 = false
        var trigger100 = false
        if ratio >= 1.0 && !alreadyAlerted100 {
            trigger100 = true
        } else if ratio >= 0.8 && !alreadyAlerted80 && !alreadyAlerted100 {
            trigger80 = true
        }
        return (trigger80, trigger100)
    }

    /// Evaluates daily spend against budget limit and checks for runaway burn rates.
    func evaluateBudgetAndQuotaAlerts() {
        let currentDay = Calendar.current.component(.day, from: Date())
        if currentDay != lastBudgetAlertDay {
            // Day rollover: reset daily budget alert flags
            didAlertBudget80 = false
            didAlertBudget100 = false
            lastBudgetAlertDay = currentDay
        }

        let config = NotchHUDConfig.shared
        guard config.usageTrackingEnabled else { return }

        // 1. Budget Threshold Alerts (80% and 100%)
        if config.notifyOnBudgetThresholds {
            let budget = max(config.dailyBudgetUSD, 0.5)
            let cost = usage.costUSD
            let (trigger80, trigger100) = Self.evaluateBudgetThreshold(
                cost: cost,
                budget: budget,
                alreadyAlerted80: didAlertBudget80,
                alreadyAlerted100: didAlertBudget100
            )

            if trigger100 {
                didAlertBudget100 = true
                didAlertBudget80 = true
                let formattedCost = String(format: "$%.2f", cost)
                let formattedBudget = String(format: "$%.2f", budget)
                ApprovalNotificationController.shared.postAlert(
                    title: "🚨 Daily AI Budget Exceeded",
                    subtitle: "Spend \(formattedCost) has reached the \(formattedBudget) limit",
                    soundName: config.errorSoundName
                )
                if let sound = NSSound(named: config.errorSoundName) {
                    sound.play()
                }
                if config.ntfyEnabled {
                    AgentAlertNotifier.notify(
                        source: "budget",
                        kind: .failed,
                        title: "🚨 Daily AI Budget Exceeded (\(formattedCost) / \(formattedBudget))",
                        roster: self.agents
                    )
                }
            } else if trigger80 {
                didAlertBudget80 = true
                let formattedCost = String(format: "$%.2f", cost)
                let formattedBudget = String(format: "$%.2f", budget)
                ApprovalNotificationController.shared.postAlert(
                    title: "⚠️ Daily AI Budget Warning",
                    subtitle: "Spend \(formattedCost) has reached 80% of \(formattedBudget) limit",
                    soundName: config.approvalSoundName
                )
                if let sound = NSSound(named: config.approvalSoundName) {
                    sound.play()
                }
                if config.ntfyEnabled {
                    AgentAlertNotifier.notify(
                        source: "budget",
                        kind: .waiting,
                        title: "⚠️ Daily AI Budget 80% (\(formattedCost) / \(formattedBudget))",
                        roster: self.agents
                    )
                }
            }
        }

        // 2. High Burn Rate Alert (Runaway agent loops)
        if config.notifyOnHighBurnRate,
            let tpm = usageRate.tokensPerMinute,
            tpm >= config.highBurnThresholdTPM
        {
            let now = Date()
            if lastHighBurnAlertDate == nil || now.timeIntervalSince(lastHighBurnAlertDate!) > 300 {
                lastHighBurnAlertDate = now
                let formattedRate = String(format: "%.0f", tpm)
                ApprovalNotificationController.shared.postAlert(
                    title: "⚡ High Token Burn Rate",
                    subtitle: "Current velocity is \(formattedRate) tokens/min",
                    soundName: config.approvalSoundName
                )
            }
        }
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
