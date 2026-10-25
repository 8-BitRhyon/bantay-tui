import Foundation

/// Token/cost usage parsed from agent transcripts (Claude Code, Codex) or
/// aggregated from kilo's SQLite ledger. The token buckets follow the
/// Anthropic-style split (input/output/reasoning/cache read/cache write).
struct UsageSnapshot: Equatable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var costUSD: Double = 0
    var costBySource: [String: Double] = [:]
    var tokensBySource: [String: Int] = [:]

    /// Legacy alias for the cache-write bucket (transcript parsers use
    /// "cache creation" terminology).
    var cacheCreationTokens: Int {
        get { cacheWriteTokens }
        set { cacheWriteTokens = newValue }
    }

    static let zero = UsageSnapshot()

    var totalTokens: Int {
        inputTokens + outputTokens + reasoningTokens + cacheReadTokens + cacheWriteTokens
    }

    /// Prompt caching savings achieved (Anthropic/OpenAI cache reads are 90% discounted vs standard input).
    var promptCacheSavingsUSD: Double {
        let standardInputRate = (Double(cacheReadTokens) / 1_000_000.0) * 3.0
        let discountedRate = (Double(cacheReadTokens) / 1_000_000.0) * 0.30
        return max(0.0, standardInputRate - discountedRate)
    }
}

/// Token rate signal for the usage gauge: tokens/min over a rolling window
/// plus the most recent transcript timestamp observed.
struct UsageRate: Equatable, Sendable {
    var tokensPerMinute: Double?
    var lastSeen: Date?
}

/// Record of an active or recent agent session for the History timeline view.
public struct AgentSessionRecord: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let agentName: String
    public let title: String
    public let startTime: Date
    public var durationSeconds: TimeInterval
    public var totalTokens: Int
    public var costUSD: Double
    public var status: String
    /// Project directory name, git branch, transcript path, and working
    /// directory captured at completion. Nil on rows recorded by older
    /// builds; the history view degrades to title-only for those.
    public var project: String?
    public var branch: String?
    public var sessionPath: String?
    public var cwd: String?
    /// True when tokens/cost are this session's own delta. Rows recorded
    /// before the delta fix hold the lifetime cumulative total instead and
    /// must be labeled and summed separately.
    public var isDelta: Bool
    /// True when the numbers are a rolling-window estimate, not a lifetime
    /// delta: the source has no metering evidence (no ledger, no transcript
    /// files). Shown plainly with a "recent" caption, never summed.
    public var isWindowEstimate: Bool

    public init(
        id: String = UUID().uuidString,
        agentName: String,
        title: String,
        startTime: Date = Date(),
        durationSeconds: TimeInterval = 0,
        totalTokens: Int = 0,
        costUSD: Double = 0.0,
        status: String = "Completed",
        project: String? = nil,
        branch: String? = nil,
        sessionPath: String? = nil,
        cwd: String? = nil,
        isDelta: Bool = false,
        isWindowEstimate: Bool = false
    ) {
        self.id = id
        self.agentName = agentName
        self.title = title
        self.startTime = startTime
        self.durationSeconds = durationSeconds
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.status = status
        self.project = project
        self.branch = branch
        self.sessionPath = sessionPath
        self.cwd = cwd
        self.isDelta = isDelta
        self.isWindowEstimate = isWindowEstimate
    }

    public var isFailed: Bool { status == "Failed" }

    /// Tolerant decoding: every field added after the first release decodes
    /// with a safe default instead of throwing. A thrown error fails the
    /// WHOLE array decode and silently wipes stored history on upgrade.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agentName = try c.decode(String.self, forKey: .agentName)
        title = try c.decode(String.self, forKey: .title)
        startTime = try c.decode(Date.self, forKey: .startTime)
        durationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds) ?? 0
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "Completed"
        project = try c.decodeIfPresent(String.self, forKey: .project)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        sessionPath = try c.decodeIfPresent(String.self, forKey: .sessionPath)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        isDelta = try c.decodeIfPresent(Bool.self, forKey: .isDelta) ?? false
        isWindowEstimate = try c.decodeIfPresent(Bool.self, forKey: .isWindowEstimate) ?? false
    }
}

/// Summary math for the sessions tab. Legacy rows (pre-delta lifetime
/// totals) are excluded from token/cost sums — adding them would multiply
/// one lifetime total by the row count. Reported separately so the header
/// can say what it left out.
public enum SessionHistorySummary: Sendable {
    public struct Totals: Equatable, Sendable {
        public let count: Int
        public let tokens: Int
        public let cost: Double
        public let failures: Int
        public let legacyExcluded: Int
    }

    public static func summarize(_ sessions: [AgentSessionRecord]) -> Totals {
        let delta = sessions.filter(\.isDelta)
        return Totals(
            count: sessions.count,
            tokens: delta.reduce(0) { $0 + $1.totalTokens },
            cost: delta.reduce(0) { $0 + $1.costUSD },
            failures: sessions.filter(\.isFailed).count,
            legacyExcluded: sessions.count - delta.count)
    }
}

/// Per-session usage delta. The live usage snapshot is cumulative per
/// source, so a finished session records current-minus-baseline (floored at
/// zero), never the lifetime total. Baselines are captured when the session
/// starts working.
public enum SessionUsageDelta: Sendable {
    public static func tokens(current: Int, baseline: Int) -> Int {
        max(0, current - baseline)
    }

    public static func cost(current: Double, baseline: Double) -> Double {
        max(0, current - baseline)
    }
}

/// Persistent store for agent session history.
@MainActor
public final class SessionHistoryStore: ObservableObject {
    public static let shared = SessionHistoryStore()
    @Published public private(set) var sessions: [AgentSessionRecord] = []

    private init() {
        loadDefaults()
    }

    private func loadDefaults() {
        if let data = UserDefaults.standard.data(forKey: "bantay_session_history"),
            let decoded = try? JSONDecoder().decode([AgentSessionRecord].self, from: data)
        {
            // Remove the three demo rows that older builds seeded on first
            // launch. Real sessions are recorded from live completion events.
            let demo = Set([
                "Apple Reminders & Antigravity detection",
                "Settings window crash fix",
                "Unit test harness suite L64",
            ])
            sessions = decoded.filter { !demo.contains($0.title) }
            // One-time migration: every stored row predates reliable
            // per-session deltas (no baselines were ever captured, and the
            // first delta build stamped lifetime totals as deltas). Mark
            // them all legacy so the summary excludes them from sums.
            if !UserDefaults.standard.bool(forKey: "bantay_session_delta_migrated") {
                sessions = sessions.map { row in
                    var legacy = row
                    legacy.isDelta = false
                    return legacy
                }
                UserDefaults.standard.set(true, forKey: "bantay_session_delta_migrated")
                save()
            }
        } else {
            sessions = []
        }
    }

    public func addSession(_ session: AgentSessionRecord) {
        guard !sessions.contains(where: { $0.id == session.id }) else { return }
        sessions.insert(session, at: 0)
        if sessions.count > 50 {
            sessions = Array(sessions.prefix(50))
        }
        save()
    }

    /// Drop rows recorded before per-session tracking. Their numbers are
    /// lifetime totals, not their own spend; deleting them loses no real
    /// per-session data.
    public func clearLegacy() {
        sessions.removeAll { !$0.isDelta }
        save()
    }

    /// Drop every recorded session, including real deltas.
    public func clearAll() {
        sessions = []
        save()
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(encoded, forKey: "bantay_session_history")
        }
    }
}

/// Color decision for the rate segment: amber at ≥ warn, red at ≥ 2× warn.
enum RateLevel: Equatable, Sendable {
    case normal, warn, red
}

/// Pure JSONL line parser for `usage`/`costUSD`/`timestamp` fields. Accepts
/// both the Claude Code shape (`"message": {"usage": {...}, "costUSD": 0.01}`)
/// and flat/rollout shapes (top-level `usage`/`costUSD`).
enum UsageParser {
    static func parse(jsonLine: String) -> UsageSnapshot? {
        guard let data = jsonLine.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let message = obj["message"] as? [String: Any]
        let usage =
            (obj["usage"] as? [String: Any])
            ?? (message?["usage"] as? [String: Any])
            ?? obj
        var snapshot = UsageSnapshot()
        snapshot.inputTokens =
            intVal(usage["input_tokens"])
            ?? intVal(usage["prompt_tokens"])
            ?? intVal(usage["inputTokens"])
            ?? intVal(usage["input"])
            ?? intVal(obj["input_tokens"])
            ?? intVal(obj["prompt_tokens"])
            ?? intVal(obj["inputTokens"])
            ?? intVal(obj["promptTokens"])
            ?? 0
        snapshot.outputTokens =
            intVal(usage["output_tokens"])
            ?? intVal(usage["completion_tokens"])
            ?? intVal(usage["outputTokens"])
            ?? intVal(usage["output"])
            ?? intVal(obj["output_tokens"])
            ?? intVal(obj["completion_tokens"])
            ?? intVal(obj["outputTokens"])
            ?? intVal(obj["completionTokens"])
            ?? 0
        snapshot.cacheReadTokens =
            intVal(usage["cache_read_input_tokens"]) ?? intVal(usage["cache_read_tokens"])
            ?? intVal(usage["cacheRead"])
            ?? 0
        snapshot.cacheCreationTokens =
            intVal(usage["cache_creation_input_tokens"]) ?? intVal(usage["cache_creation_tokens"])
            ?? intVal(usage["cacheWrite"])
            ?? 0
        snapshot.reasoningTokens = intVal(usage["reasoning"]) ?? 0
        // Pi emits a precomputed cost object — real USD, authoritative. Prefer
        // it over the flat costUSD fields and never apply the $3/$15 estimate
        // to Pi data (its model rates are far cheaper).
        let piCost =
            ((usage["cost"] as? [String: Any])?["total"] as? NSNumber)?.doubleValue
            ?? ((usage["cost"] as? [String: Any])?["total"] as? String).flatMap(Double.init)
        if let cost = double(obj["costUSD"]) ?? double(message?["costUSD"])
            ?? double(obj["cost_usd"])
            ?? piCost
        {
            snapshot.costUSD = cost
        } else if snapshot.totalTokens > 0, piCost == nil {
            let regularInputCost = (Double(snapshot.inputTokens) / 1_000_000.0) * 3.0
            let cacheReadCost = (Double(snapshot.cacheReadTokens) / 1_000_000.0) * 0.30
            let cacheWriteCost = (Double(snapshot.cacheCreationTokens) / 1_000_000.0) * 3.75
            let outputCost = (Double(snapshot.outputTokens) / 1_000_000.0) * 15.0
            snapshot.costUSD = regularInputCost + cacheReadCost + cacheWriteCost + outputCost
        }
        guard snapshot.totalTokens > 0 || snapshot.costUSD > 0 else { return nil }
        return snapshot
    }

    private static func intVal(_ val: Any?) -> Int? {
        if let i = val as? Int { return i }
        if let d = val as? Double { return Int(d) }
        if let s = val as? String, let i = Int(s) { return i }
        return nil
    }

    static func parseAll(lines: [String]) -> UsageSnapshot {
        lines.reduce(into: UsageSnapshot.zero) { total, line in
            guard let part = parse(jsonLine: line) else { return }
            total.inputTokens += part.inputTokens
            total.outputTokens += part.outputTokens
            total.cacheReadTokens += part.cacheReadTokens
            total.cacheCreationTokens += part.cacheCreationTokens
            total.reasoningTokens += part.reasoningTokens
            total.costUSD += part.costUSD
        }
    }

    /// Stable identity for one metered turn. One API turn fans out to N
    /// streamed lines repeating identical usage; summing them raw counts
    /// every turn N times (Claude streamed blocks, subagent double-logs).
    /// Nil when the line carries no identity — unidentified lines are always
    /// counted, never silently dropped.
    static func messageID(jsonLine: String) -> String? {
        guard let data = jsonLine.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let message = obj["message"] as? [String: Any]
        let mid =
            (message?["id"] as? String) ?? (obj["messageId"] as? String)
            ?? (obj["message_id"] as? String)
        if let rid = (obj["requestId"] as? String) ?? (obj["request_id"] as? String),
            !rid.isEmpty
        {
            return "\(mid ?? "?"):\(rid)"
        }
        if let uuid = (obj["uuid"] as? String) ?? (obj["id"] as? String),
            !uuid.isEmpty
        {
            if let mid, !mid.isEmpty { return "\(mid):\(uuid)" }
            return uuid
        }
        if let mid, !mid.isEmpty { return mid }
        return nil
    }

    /// Sum usage while counting each metered turn once. Returns the snapshot
    /// plus the updated identity set, so incremental tailing stays exact
    /// across polls. `parseAll` keeps its raw-sum semantics for callers that
    /// already operate on deduped lines.
    static func parseAllDeduped(
        lines: [String], seen: Set<String> = []
    ) -> (usage: UsageSnapshot, seen: Set<String>) {
        var next = seen
        var total = UsageSnapshot.zero
        for line in lines {
            if let id = messageID(jsonLine: line) {
                guard !next.contains(id) else { continue }
                next.insert(id)
            }
            guard let part = parse(jsonLine: line) else { continue }
            total.inputTokens += part.inputTokens
            total.outputTokens += part.outputTokens
            total.cacheReadTokens += part.cacheReadTokens
            total.cacheCreationTokens += part.cacheCreationTokens
            total.reasoningTokens += part.reasoningTokens
            total.costUSD += part.costUSD
        }
        return (total, next)
    }

    /// Parses ISO-8601 timestamps from transcript lines.
    static func parseTimestamp(_ line: String) -> Date? {
        guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let numeric = (obj["timestamp"] as? NSNumber)?.doubleValue {
            // Pi assistant/tool messages carry unix epoch ms; treat 1e12-ish
            // values as ms and 1e9-ish values as seconds.
            if numeric > 1e11 { return Date(timeIntervalSince1970: numeric / 1000) }
            return Date(timeIntervalSince1970: numeric)
        }
        guard
            let raw =
                (obj["timestamp"] as? String)
                ?? ((obj["message"] as? [String: Any])?["timestamp"] as? String)
        else {
            return nil
        }
        return parseISODate(raw)
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func int(_ value: Any?) -> Int {
        guard let number = value as? NSNumber else { return 0 }
        return number.intValue
    }

    private static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }
}

/// Aggregation + budget math for the notch usage gauge.
enum UsageTracker {
    static func aggregate(_ snapshots: [UsageSnapshot]) -> UsageSnapshot {
        snapshots.reduce(into: UsageSnapshot.zero) { total, part in
            total.inputTokens += part.inputTokens
            total.outputTokens += part.outputTokens
            total.cacheReadTokens += part.cacheReadTokens
            total.cacheCreationTokens += part.cacheCreationTokens
            total.reasoningTokens += part.reasoningTokens
            total.costUSD += part.costUSD
            for (source, cost) in part.costBySource {
                total.costBySource[source, default: 0] += cost
            }
            for (source, tokens) in part.tokensBySource {
                total.tokensBySource[source, default: 0] += tokens
            }
        }
    }

    /// 0...1 fraction of the session budget consumed, clamped.
    static func fractionUsed(costUSD: Double, budgetUSD: Double) -> Double {
        guard budgetUSD > 0 else { return 0 }
        return min(max(costUSD / budgetUSD, 0), 1)
    }

    /// Calculates tokens per minute across transcript lines within the specified window.
    static func rate(lines: [String], now: Date, window: TimeInterval) -> UsageRate {
        guard window > 0 else { return UsageRate(tokensPerMinute: nil, lastSeen: nil) }
        let windowStart = now.addingTimeInterval(-window)
        var dated: [(date: Date, tokens: Int)] = []
        var lastSeen: Date?
        for line in lines {
            guard let date = UsageParser.parseTimestamp(line) else { continue }
            guard date >= windowStart, date <= now else { continue }
            let tokens = max(UsageParser.parse(jsonLine: line)?.totalTokens ?? 0, 0)
            dated.append((date, tokens))
            lastSeen = lastSeen.map { max($0, date) } ?? date
        }
        guard let last = lastSeen else {
            return UsageRate(tokensPerMinute: nil, lastSeen: nil)
        }
        dated.sort { $0.date < $1.date }
        let span = dated[dated.count - 1].date.timeIntervalSince(dated[0].date)
        guard span > 0 else {
            return UsageRate(tokensPerMinute: nil, lastSeen: last)
        }
        let totalTokens = max(dated.reduce(0) { $0 + $1.tokens }, 0)
        return UsageRate(
            tokensPerMinute: Double(totalTokens) / (span / 60), lastSeen: last)
    }

    /// Color decision for the rate segment. warn at exactly threshold, red at
    /// exactly 2× threshold (boundaries inclusive).
    static func rateLevel(rate: Double, warn: Int) -> RateLevel {
        let threshold = Double(max(warn, 1))
        if rate >= 2 * threshold { return .red }
        if rate >= threshold { return .warn }
        return .normal
    }

    /// Compact token count. Delegates to the single formatter so session
    /// rows, spend headers, and digests never show divergent suffixes
    /// (`3.4m` vs `3.4M`).
    static func compactTokens(_ count: Int) -> String {
        IslandMetrics.compactTokenCount(count)
    }

    /// Sum usage across the newest transcript of each agent family.
    static func latestUsage(home: String, names: [String]) -> UsageSnapshot {
        latestUsageAndRate(home: home, names: names, now: Date(), window: 60).usage
    }

    /// Reads usage and token burn rate over recent transcripts in a single pass.
    /// Transcript usage is attributed per agent family so session records and
    /// the spend ledger can break tokens and cost down by source.
    static func latestUsageAndRate(
        home: String, names: [String], now: Date, window: TimeInterval
    ) -> (usage: UsageSnapshot, rate: UsageRate) {
        let lowered = names.map { $0.lowercased() }
        var rootOwners: [String: [String]] = [:]
        for name in lowered {
            for root in AgentDetector.transcriptSearchPaths(home: home, name: name) {
                rootOwners[root, default: []].append(name)
            }
        }
        var combined = UsageSnapshot.zero
        var rateLines: [String] = []
        for (root, owners) in rootOwners {
            guard let lines = UsageTracker.tailLines(root: root, maxBytes: 32_000) else {
                continue
            }
            let usage = UsageParser.parseAll(lines: lines)
            if usage.totalTokens > 0 || usage.costUSD > 0 {
                combined = aggregate([combined, usage])
                for owner in owners {
                    combined.tokensBySource[owner, default: 0] += usage.totalTokens
                    combined.costBySource[owner, default: 0] += usage.costUSD
                }
            }
            rateLines.append(contentsOf: lines)
        }
        if lowered.contains("opencode"),
            let opencodeSnap = OpenCodeUsageAdapter.snapshot(
                since: 24 * 3600, now: now, home: home)
        {
            combined = aggregate([combined, opencodeSnap])
        }
        if lowered.contains("codex"),
            let codexSnap = CodexUsageAdapter.snapshot(since: 24 * 3600, now: now, home: home)
        {
            combined = aggregate([combined, codexSnap])
        }
        if lowered.contains("cursor"),
            let cursorSnap = CursorUsageAdapter.snapshot(now: now, home: home)
        {
            combined = aggregate([combined, cursorSnap])
        }
        return (combined, UsageTracker.rate(lines: rateLines, now: now, window: window))
    }

    /// Newest transcript file under `root`, tailed as lines.
    static func tailLines(root: String, maxBytes: Int) -> [String]? {
        guard
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }
        var best: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            guard isTranscriptFile(url),
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true
            else {
                continue
            }
            let date = values.contentModificationDate ?? .distantPast
            if best == nil || date > best!.date {
                best = (url, date)
            }
        }
        guard let best else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: best.url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// One file filter for every transcript scan: regular JSONL/log/JSON/TXT
    /// files or log-named files. Shared so the tail reader, the change
    /// fingerprint, and the lifetime accrual never disagree on coverage.
    static func isTranscriptFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        return ext == "jsonl" || ext == "log" || ext == "json" || ext == "txt"
            || name.contains("log")
    }

    /// Per-file (path, size, mtime) fingerprint of every candidate transcript
    /// file under `root`. Root-dir mtime alone goes stale: the directory
    /// entry rarely changes when a nested file grows, so new usage would
    /// never surface. Staleness must be per file.
    static func transcriptFingerprint(root: String) -> String {
        guard
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [
                    .contentModificationDateKey, .isRegularFileKey, .fileSizeKey,
                ],
                options: [.skipsHiddenFiles]
            )
        else {
            return "missing"
        }
        var parts: [String] = []
        for case let url as URL in enumerator {
            guard isTranscriptFile(url),
                let values = try? url.resourceValues(
                    forKeys: [
                        .contentModificationDateKey, .isRegularFileKey, .fileSizeKey,
                    ]),
                values.isRegularFile == true,
                let size = values.fileSize,
                let date = values.contentModificationDate
            else {
                continue
            }
            parts.append("\(url.path)=\(size)@\(Int(date.timeIntervalSince1970))")
        }
        return parts.sorted().joined(separator: "|")
    }

    /// Incremental lifetime accrual state. Byte offsets plus the metered-turn
    /// identity set make re-reads exact: only appended bytes parse, and each
    /// turn counts once no matter how often its lines repeat.
    struct LifetimeAccrualState: Sendable {
        var sizes: [String: UInt64] = [:]
        var seen: Set<String> = []
        var tokensBySource: [String: Int] = [:]
        var costBySource: [String: Double] = [:]
        /// Sources with metering evidence: files read, or a ledger snapshot.
        /// Only covered sources get true per-session deltas; the rest fall
        /// back to rolling-window values, honestly labeled downstream.
        var covered: Set<String> = []
    }

    /// Sources whose lifetime counters come from an authoritative ledger,
    /// never from transcript tails. Parsing tails for them would double
    /// count every token.
    static let ledgerCoveredSources: Set<String> = ["opencode"]

    /// Accrue lifetime per-source usage from transcript files. Reads only
    /// bytes appended since the last call (full file on first sight, capped
    /// per file), dedupes metered turns, attributes to every owning source.
    /// Pure apart from the filesystem reads; the caller keeps `state`.
    static func accrueLifetime(
        home: String, names: [String], state: LifetimeAccrualState,
        maxFirstReadBytes: Int = 1_048_576
    ) -> LifetimeAccrualState {
        var next = state
        let lowered = names.map { $0.lowercased() }
        var rootOwners: [String: [String]] = [:]
        for name in lowered where !ledgerCoveredSources.contains(name) {
            for root in AgentDetector.transcriptSearchPaths(home: home, name: name) {
                rootOwners[root, default: []].append(name)
            }
        }
        for (root, owners) in rootOwners {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: root, isDirectory: true),
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                continue
            }
            var sawFile = false
            for case let url as URL in enumerator {
                guard isTranscriptFile(url),
                    let values = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .fileSizeKey]),
                    values.isRegularFile == true,
                    let size = values.fileSize, size > 0
                else {
                    continue
                }
                let path = url.path
                let consumed = next.sizes[path] ?? 0
                let sizeU = UInt64(size)
                sawFile = true
                let start: UInt64
                if consumed > sizeU {
                    // Rotated or truncated: re-read from zero. Message ids
                    // still dedupe, so only unidentified lines can recount.
                    start = 0
                } else if consumed == 0, sizeU > UInt64(maxFirstReadBytes) {
                    // First sight of a huge file: skip the ancient head.
                    // Lifetime starts slightly short rather than stalling poll.
                    start = sizeU - UInt64(maxFirstReadBytes)
                } else {
                    start = consumed
                }
                guard start < sizeU,
                    let handle = try? FileHandle(forReadingFrom: url)
                else {
                    next.sizes[path] = sizeU
                    continue
                }
                defer { try? handle.close() }
                try? handle.seek(toOffset: start)
                let data = handle.readDataToEndOfFile()
                next.sizes[path] = sizeU
                let text = String(decoding: data, as: UTF8.self)
                let lines = text.split(whereSeparator: \.isNewline).map(String.init)
                guard !lines.isEmpty else { continue }
                let (usage, seen) = UsageParser.parseAllDeduped(lines: lines, seen: next.seen)
                next.seen = seen
                guard usage.totalTokens > 0 || usage.costUSD > 0 else { continue }
                for owner in owners {
                    next.tokensBySource[owner, default: 0] += usage.totalTokens
                    next.costBySource[owner, default: 0] += usage.costUSD
                }
            }
            if sawFile {
                for owner in owners {
                    next.covered.insert(owner)
                }
            }
        }
        return next
    }

    /// PERF-2: the transcript root's directory mtime — a cheap sentinel for
    /// "did anything under this root change". The caller memoizes this and
    /// skips the expensive `tailLines` enumeration+read when unchanged.
    static func transcriptMtime(root: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: root))?[.modificationDate]
            as? Date
    }
}
