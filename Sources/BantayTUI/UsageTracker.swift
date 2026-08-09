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
}

/// Token rate signal for the usage gauge: tokens/min over a rolling window
/// plus the most recent transcript timestamp observed.
struct UsageRate: Equatable, Sendable {
    var tokensPerMinute: Double?
    var lastSeen: Date?
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
            ?? intVal(obj["input_tokens"])
            ?? intVal(obj["prompt_tokens"])
            ?? 0
        snapshot.outputTokens =
            intVal(usage["output_tokens"])
            ?? intVal(usage["completion_tokens"])
            ?? intVal(usage["outputTokens"])
            ?? intVal(obj["output_tokens"])
            ?? intVal(obj["completion_tokens"])
            ?? 0
        snapshot.cacheReadTokens =
            intVal(usage["cache_read_input_tokens"]) ?? intVal(usage["cache_read_tokens"]) ?? 0
        snapshot.cacheCreationTokens =
            intVal(usage["cache_creation_input_tokens"]) ?? intVal(usage["cache_creation_tokens"])
            ?? 0
        if let cost = double(obj["costUSD"]) ?? double(message?["costUSD"])
            ?? double(obj["cost_usd"])
        {
            snapshot.costUSD = cost
        } else if snapshot.totalTokens > 0 {
            let inputCost =
                (Double(
                    snapshot.inputTokens + snapshot.cacheReadTokens + snapshot.cacheCreationTokens)
                    / 1_000_000.0) * 3.0
            let outputCost = (Double(snapshot.outputTokens) / 1_000_000.0) * 15.0
            snapshot.costUSD = inputCost + outputCost
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

    /// ISO-8601 timestamp carried by transcript lines. Claude Code and Codex
    /// both emit a top-level `"timestamp"` per JSONL line; a few Claude Code
    /// lines nest it under `message.timestamp`. Returns nil when absent or
    /// unparseable.
    static func parseTimestamp(_ line: String) -> Date? {
        guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
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
        }
    }

    /// 0...1 fraction of the session budget consumed, clamped.
    static func fractionUsed(costUSD: Double, budgetUSD: Double) -> Double {
        guard budgetUSD > 0 else { return 0 }
        return min(max(costUSD / budgetUSD, 0), 1)
    }

    /// Tokens/min across the transcript lines inside `window` ending at `now`.
    /// Absolute timestamps only (DST/midnight-safe). Each line's own token
    /// count is its incremental contribution — the same shape `parseAll`
    /// aggregates — so the rate is (sum of in-window tokens) ÷ elapsed time
    /// between the first and last in-window line. Returns nil when the window
    /// is 0/negative, no line carries a parseable timestamp, or fewer than
    /// two distinct timestamps fall in the window (no division by zero).
    /// Negative token deltas clamp to 0 (clock skew between lines).
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

    /// Compact token count: "1.2k", "3.4m".
    static func compactTokens(_ count: Int) -> String {
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

    /// Usage plus the tokens/min rate over the newest transcripts, read in a
    /// single pass per transcript root.
    /// NOTE (M9): the fallback cost estimate ($3/M in + $15/M out) is a
    /// display aid, not accounting — and a session present under two roots of
    /// one family (e.g. .claude/projects + .claude/transcripts) is counted
    /// twice. Acceptable for a spend gauge; a precise figure needs per-session
    /// dedupe keyed by session id.
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
        let text = String(data: data, encoding: .utf8) ?? ""
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
