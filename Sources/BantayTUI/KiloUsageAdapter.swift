import Foundation
import SQLite3

/// A single usage sample normalized across agents (the scalable provider
/// protocol). Every adapter emits this shape; the store aggregates by
/// `source:sessionID`.
struct UsageSample: Equatable, Sendable {
    let source: String
    /// "per-message" = this sample is one provider call (sum to total);
    /// "cumulative" = this sample is a running total (use latest, diff for rate).
    let mode: String
    let sessionID: String
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let costUSD: Double
    /// Agent-reported timestamp (epoch seconds); used for event-based tpm.
    let occurredAt: Double
    /// Wall-clock when Bantay observed it.
    let observedAt: Double
}

/// Reads kilo's token/cost ledger directly from its SQLite DB — the source of
/// truth behind `kilo stats`. The `session` table carries per-session
/// aggregates (`cost`, `tokens_input/output/reasoning/cache_read/write`,
/// `time_updated`), so:
///   - daily cost / quota = SUM(cost) over sessions with time_updated in window
///   - tokens-per-minute  = poll SUM(tokens_*) and diff over wall-clock time,
///     or exact per-minute history via the `message` table's time_created.
/// Read-only sqlite3 (WAL-safe) so kilo can keep running.
enum KiloUsageAdapter {
    static let sourceName = "kilo"

    static func databaseURL() -> URL {
        let home = NSHomeDirectory()
        // `kilo db path` canonical location; XDG_* overrides respected below.
        let env = ProcessInfo.processInfo.environment
        if let data = env["KILO_DATA_DIR"] {
            return URL(fileURLWithPath: data).appendingPathComponent("kilo.db")
        }
        return URL(fileURLWithPath: "\(home)/.local/share/kilo/kilo.db")
    }

    /// Whether kilo's DB is present and queryable.
    static func detect() -> Bool {
        FileManager.default.fileExists(atPath: databaseURL().path)
    }

    /// Aggregate usage over the last `window` seconds (per session's
    /// `time_updated`). `nil` if the DB is missing/unreadable.
    static func snapshot(since window: TimeInterval, now: Date = Date()) -> UsageSnapshot? {
        let url = databaseURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let sinceMs = Int64((now.timeIntervalSince1970 - window) * 1000)
        // Use the `session` aggregate columns; prefer real cost when nonzero.
        let sql =
            "SELECT COALESCE(SUM(cost),0), COALESCE(SUM(tokens_input),0), "
            + "COALESCE(SUM(tokens_output),0), COALESCE(SUM(tokens_reasoning),0), "
            + "COALESCE(SUM(tokens_cache_read),0), COALESCE(SUM(tokens_cache_write),0) "
            + "FROM session WHERE time_updated >= \(sinceMs)"
        guard
            let row = sqlite3Query(sql: sql, db: url)?.first,
            row.count >= 6,
            let cost = Double(row[0]),
            let input = Int(row[1]),
            let output = Int(row[2]),
            let reasoning = Int(row[3]),
            let cacheRead = Int(row[4]),
            let cacheWrite = Int(row[5])
        else { return nil }
        return UsageSnapshot(
            inputTokens: input, outputTokens: output, reasoningTokens: reasoning,
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, costUSD: cost)
    }

    /// Per-minute token history (exact) via the `message` table's
    /// `time_created` (epoch ms), bucketed per minute for the last `window`
    /// seconds. Returns [(minuteEpoch, inputTokens, totalTokens)].
    static func perMinuteHistory(since window: TimeInterval, now: Date = Date()) -> [(
        Int, Int, Int
    )] {
        let url = databaseURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let sinceMs = Int64((now.timeIntervalSince1970 - window) * 1000)
        let sql =
            "SELECT (time_created/60000) AS minute_epoch, "
            + "SUM(json_extract(data,'$.tokens.input')) AS input_tokens, "
            + "SUM(json_extract(data,'$.tokens.output')) AS output_tokens, "
            + "SUM(json_extract(data,'$.tokens.cache.read')) AS cache_read "
            + "FROM message "
            + "WHERE json_extract(data,'$.role')='assistant' "
            + "AND time_created >= \(sinceMs) "
            + "GROUP BY minute_epoch ORDER BY minute_epoch"
        guard let rows = sqlite3Query(sql: sql, db: url) else { return [] }
        return rows.compactMap { row in
            guard
                let minute = Int(row[0]),
                let input = Int(row[1]),
                let output = Int(row[2]),
                let cacheRead = Int(row[3])
            else { return nil }
            return (minute, input, input + output + cacheRead)
        }
    }

    /// Poll-and-diff tokens-per-minute: call `snapshot` twice N seconds apart
    /// and divide the delta by the window in minutes. Reliable for any agent
    /// whose totals are cumulative.
    static func rateFromDeltas(before: UsageSnapshot, after: UsageSnapshot, window: TimeInterval)
        -> Double
    {
        let delta = Double(max(after.totalTokens - before.totalTokens, 0))
        return delta / (window / 60.0)
    }

    // MARK: - sqlite3 helper (read-only)

    private static func sqlite3Query(sql: String, db: URL) -> [[String]]? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(db.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if handle != nil { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cols = sqlite3_column_count(stmt)
            var row: [String] = []
            for i in 0..<cols {
                if let text = sqlite3_column_text(stmt, i) {
                    row.append(String(cString: text))
                } else {
                    row.append("")
                }
            }
            rows.append(row)
        }
        return rows
    }
}
