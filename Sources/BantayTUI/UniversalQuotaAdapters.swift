import Foundation
import SQLite3

/// Universal adapter reading OpenAI Codex thread tokens from `~/.codex/state_5.sqlite`.
enum CodexUsageAdapter {
    static func databaseURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: "\(home)/.codex/state_5.sqlite")
    }

    /// Whether Codex's SQLite state database is present on disk.
    static func detect(home: String = NSHomeDirectory()) -> Bool {
        FileManager.default.fileExists(atPath: databaseURL(home: home).path)
    }

    /// Aggregate usage across Codex threads updated within `window` seconds.
    static func snapshot(
        since window: TimeInterval,
        now: Date = Date(),
        home: String = NSHomeDirectory()
    ) -> UsageSnapshot? {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let sinceMs = Int64((now.timeIntervalSince1970 - window) * 1000)
        let sql =
            "SELECT COALESCE(SUM(tokens_used), 0) FROM threads WHERE updated_at_ms >= \(sinceMs)"

        guard let row = sqlite3Query(sql: sql, db: url)?.first,
            let tokens = Int(row.first ?? "0"),
            tokens > 0
        else {
            return nil
        }

        // Standard estimate: $3 per 1M tokens for Codex/GPT-4o class reasoning
        let cost = (Double(tokens) / 1_000_000.0) * 3.0
        var snapshot = UsageSnapshot()
        snapshot.inputTokens = Int(Double(tokens) * 0.75)
        snapshot.outputTokens = Int(Double(tokens) * 0.25)
        snapshot.costUSD = cost
        snapshot.costBySource["codex"] = cost
        return snapshot
    }

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

/// Universal adapter reading Cursor AI daily statistics from `state.vscdb`.
enum CursorUsageAdapter {
    static func databaseURL(home: String = NSHomeDirectory()) -> URL {
        URL(
            fileURLWithPath:
                "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Whether Cursor's SQLite state database is present on disk.
    static func detect(home: String = NSHomeDirectory()) -> Bool {
        FileManager.default.fileExists(atPath: databaseURL(home: home).path)
    }

    /// Query daily stats JSON line records from Cursor's ItemTable.
    static func snapshot(
        now: Date = Date(),
        home: String = NSHomeDirectory()
    ) -> UsageSnapshot? {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let sql =
            "SELECT value FROM ItemTable WHERE key LIKE 'aiCodeTracking.dailyStats%' ORDER BY key DESC LIMIT 1"
        guard let row = sqlite3Query(sql: sql, db: url)?.first,
            let jsonStr = row.first,
            let data = jsonStr.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let suggested = (obj["composerSuggestedLines"] as? NSNumber)?.intValue ?? 0
        let accepted = (obj["composerAcceptedLines"] as? NSNumber)?.intValue ?? 0
        let tabAccepted = (obj["tabAcceptedLines"] as? NSNumber)?.intValue ?? 0
        let totalLines = suggested + accepted + tabAccepted
        guard totalLines > 0 else { return nil }

        // Approximate 25 tokens per diff line for standard code syntax
        let estTokens = totalLines * 25
        let cost = (Double(estTokens) / 1_000_000.0) * 3.5

        var snapshot = UsageSnapshot()
        snapshot.inputTokens = Int(Double(estTokens) * 0.6)
        snapshot.outputTokens = Int(Double(estTokens) * 0.4)
        snapshot.costUSD = cost
        snapshot.costBySource["cursor"] = cost
        return snapshot
    }

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
