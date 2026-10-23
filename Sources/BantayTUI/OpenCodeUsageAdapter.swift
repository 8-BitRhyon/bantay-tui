import Foundation
import SQLite3

/// Reads token and cost metrics from opencode's SQLite ledger
/// (`~/.local/share/opencode/opencode.db`). opencode keeps every assistant
/// message, with exact `tokens` and `cost` JSON, in `session_message` — the
/// transcript-file parsers never see it, so without this adapter opencode
/// spend is invisible to the history views.
enum OpenCodeUsageAdapter {
    static let sourceName = "opencode"

    static func databaseURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: "\(home)/.local/share/opencode/opencode.db")
    }

    static func detect(home: String = NSHomeDirectory()) -> Bool {
        FileManager.default.fileExists(atPath: databaseURL(home: home).path)
    }

    /// Aggregate usage over the last `window` seconds, keyed by message
    /// creation time (epoch ms). Returns nil when the DB is missing or empty.
    static func snapshot(
        since window: TimeInterval,
        now: Date = Date(),
        home: String = NSHomeDirectory()
    ) -> UsageSnapshot? {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let sinceMs = Int64((now.timeIntervalSince1970 - window) * 1000)
        let sql =
            "SELECT COALESCE(SUM(CAST(json_extract(data,'$.tokens.input') AS INTEGER)),0),"
            + " COALESCE(SUM(CAST(json_extract(data,'$.tokens.output') AS INTEGER)),0),"
            + " COALESCE(SUM(CAST(json_extract(data,'$.tokens.reasoning') AS INTEGER)),0),"
            + " COALESCE(SUM(CAST(json_extract(data,'$.tokens.cache.read') AS INTEGER)),0),"
            + " COALESCE(SUM(CAST(json_extract(data,'$.tokens.cache.write') AS INTEGER)),0),"
            + " COALESCE(SUM(CAST(json_extract(data,'$.cost') AS REAL)),0)"
            + " FROM session_message WHERE type='assistant' AND time_created >= \(sinceMs)"
        guard
            let row = sqlite3QueryOpenCode(sql: sql, db: url)?.first,
            row.count >= 6,
            let input = Int(row[0]),
            let output = Int(row[1]),
            let reasoning = Int(row[2]),
            let cacheRead = Int(row[3]),
            let cacheWrite = Int(row[4]),
            let cost = Double(row[5])
        else { return nil }
        guard input + output + reasoning + cacheRead + cacheWrite > 0 || cost > 0 else {
            return nil
        }
        var snapshot = UsageSnapshot()
        snapshot.inputTokens = input
        snapshot.outputTokens = output
        snapshot.reasoningTokens = reasoning
        snapshot.cacheReadTokens = cacheRead
        snapshot.cacheWriteTokens = cacheWrite
        snapshot.costUSD = cost
        snapshot.costBySource[sourceName] = cost
        snapshot.tokensBySource[sourceName] =
            input + output + reasoning + cacheRead
            + cacheWrite
        return snapshot
    }

    private static func sqlite3QueryOpenCode(sql: String, db: URL) -> [[String]]? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let uriPath = "file://\(db.path)?immutable=1&mode=ro"
        guard sqlite3_open_v2(uriPath, &handle, flags, nil) == SQLITE_OK, let handle else {
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
