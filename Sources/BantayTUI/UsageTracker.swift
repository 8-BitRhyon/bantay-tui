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

    public init(
        id: String = UUID().uuidString,
        agentName: String,
        title: String,
        startTime: Date = Date(),
        durationSeconds: TimeInterval = 0,
        totalTokens: Int = 0,
        costUSD: Double = 0.0,
        status: String = "Completed"
    ) {
        self.id = id
        self.agentName = agentName
        self.title = title
        self.startTime = startTime
        self.durationSeconds = durationSeconds
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.status = status
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
            sessions = decoded
        } else {
            sessions = [
                AgentSessionRecord(
                    agentName: "antigravity", title: "Apple Reminders & Antigravity detection",
                    startTime: Date().addingTimeInterval(-1800), durationSeconds: 320,
                    totalTokens: 14500, costUSD: 0.18, status: "Completed"),
                AgentSessionRecord(
                    agentName: "claude", title: "Settings window crash fix",
                    startTime: Date().addingTimeInterval(-3600), durationSeconds: 410,
                    totalTokens: 28900, costUSD: 0.42, status: "Completed"),
                AgentSessionRecord(
                    agentName: "codex", title: "Unit test harness suite L64",
                    startTime: Date().addingTimeInterval(-7200), durationSeconds: 190,
                    totalTokens: 8200, costUSD: 0.12, status: "Completed"),
            ]
        }
    }

    public func addSession(_ session: AgentSessionRecord) {
        sessions.insert(session, at: 0)
        if sessions.count > 50 {
            sessions = Array(sessions.prefix(50))
        }
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
            total.costUSD += part.costUSD
        }
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
            total.costUSD += part.costUSD
            for (source, cost) in part.costBySource {
                total.costBySource[source, default: 0] += cost
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

    /// Compact token count: "1.2k", "3.4m", "5.6b".
    static func compactTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fb", Double(count) / 1_000_000_000)
        }
        if count >= 1_000_000 {
            return String(format: "%.1fm", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return "\(count)"
    }

    /// Sum usage across the newest transcript of each agent family.
    static func latestUsage(home: String, names: [String]) -> UsageSnapshot {
        latestUsageAndRate(home: home, names: names, now: Date(), window: 60).usage
    }

    /// Reads usage and token burn rate over recent transcripts in a single pass.
    static func latestUsageAndRate(
        home: String, names: [String], now: Date, window: TimeInterval
    ) -> (usage: UsageSnapshot, rate: UsageRate) {
        let roots: Set<String> = Set(
            names.flatMap { AgentDetector.transcriptSearchPaths(home: home, name: $0) })
        var combined = UsageSnapshot.zero
        var rateLines: [String] = []
        for root in roots {
            guard let lines = UsageTracker.tailLines(root: root, maxBytes: 32_000) else {
                continue
            }
            let usage = UsageParser.parseAll(lines: lines)
            if usage.totalTokens > 0 || usage.costUSD > 0 {
                combined = aggregate([combined, usage])
            }
            rateLines.append(contentsOf: lines)
        }
        if names.contains(where: { $0.lowercased() == "codex" }),
            let codexSnap = CodexUsageAdapter.snapshot(since: 24 * 3600, now: now, home: home)
        {
            combined = aggregate([combined, codexSnap])
        }
        if names.contains(where: { $0.lowercased() == "cursor" }),
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
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent.lowercased()
            guard
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true,
                ext == "jsonl" || ext == "log" || ext == "json" || ext == "txt"
                    || name.contains("log")
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

    /// PERF-2: the transcript root's directory mtime — a cheap sentinel for
    /// "did anything under this root change". The caller memoizes this and
    /// skips the expensive `tailLines` enumeration+read when unchanged.
    static func transcriptMtime(root: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: root))?[.modificationDate]
            as? Date
    }
}
