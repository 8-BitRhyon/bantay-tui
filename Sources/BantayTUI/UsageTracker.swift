import Foundation

/// Token/cost usage parsed from agent transcripts (Claude Code, Codex).
struct UsageSnapshot: Equatable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var costUSD: Double = 0

    static let zero = UsageSnapshot()

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }
}

/// Pure JSONL line parser for `usage`/`costUSD` fields. Accepts both the
/// Claude Code shape (`"message": {"usage": {...}, "costUSD": 0.01}`) and
/// flat/rollout shapes (top-level `usage`/`costUSD`).
enum UsageParser {
    static func parse(jsonLine: String) -> UsageSnapshot? {
        guard let data = jsonLine.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let message = obj["message"] as? [String: Any]
        guard
            let usage = (obj["usage"] as? [String: Any])
                ?? (message?["usage"] as? [String: Any])
        else {
            return nil
        }
        var snapshot = UsageSnapshot()
        snapshot.inputTokens = int(usage["input_tokens"])
        snapshot.outputTokens = int(usage["output_tokens"])
        snapshot.cacheReadTokens = int(usage["cache_read_input_tokens"])
        snapshot.cacheCreationTokens = int(usage["cache_creation_input_tokens"])
        if let cost = double(obj["costUSD"]) ?? double(message?["costUSD"]) {
            snapshot.costUSD = cost
        }
        return snapshot
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
        let roots: Set<String> = Set(
            names.compactMap { AgentDetector.transcriptSearchPaths(home: home, name: $0).first })
        let snapshots: [UsageSnapshot] = roots.compactMap { root in
            guard let lines = UsageTracker.tailLines(root: root, maxBytes: 32_000) else {
                return nil
            }
            let usage = UsageParser.parseAll(lines: lines)
            return usage.totalTokens > 0 || usage.costUSD > 0 ? usage : nil
        }
        return aggregate(snapshots)
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
            guard
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true,
                url.pathExtension == "jsonl" || url.lastPathComponent == "rollout.jsonl"
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
}
