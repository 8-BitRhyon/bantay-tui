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

    /// Quota wall state from the ledger: whether recent assistant messages
    /// hit a provider limit (opencode free-tier QuotaExceeded), plus today's
    /// measured cost, tokens, and latest model. Nil when opencode has no
    /// recent activity, so unused installs never produce a quota row.
    struct QuotaState: Equatable, Sendable {
        let limitReached: Bool
        let model: String?
        let costTodayUSD: Double
        let tokensToday: Int
    }

    /// Dollar spend for one OpenCode Go model across the three Go allowance
    /// windows (5-hour, weekly, monthly), read from the ledger's own cost
    /// accounting.
    struct GoModelSpend: Equatable, Sendable {
        let modelID: String
        let spend5h: Double
        let spend7d: Double
        let spend30d: Double
    }

    static func quotaState(
        now: Date = Date(),
        home: String = NSHomeDirectory()
    ) -> QuotaState? {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let calendar = Calendar.current
        let startOfDayMs = Int64(
            calendar.startOfDay(for: now).timeIntervalSince1970 * 1000)
        // Free-tier bucket only: opencode-go traffic counts toward Go plan
        // limits, never toward the free wall.
        let freeFilter =
            "AND (json_extract(data,'$.model.providerID') IS NULL"
            + " OR json_extract(data,'$.model.providerID') != 'opencode-go')"
        let usageSql =
            "SELECT COUNT(*),"
            + " COALESCE(SUM(CAST(json_extract(data,'$.cost') AS REAL)),0),"
            + " COALESCE(SUM(CAST(json_extract(data,'$.tokens.input') AS INTEGER)),0)"
            + " + COALESCE(SUM(CAST(json_extract(data,'$.tokens.output') AS INTEGER)),0)"
            + " + COALESCE(SUM(CAST(json_extract(data,'$.tokens.reasoning') AS INTEGER)),0)"
            + " + COALESCE(SUM(CAST(json_extract(data,'$.tokens.cache.read') AS INTEGER)),0)"
            + " + COALESCE(SUM(CAST(json_extract(data,'$.tokens.cache.write') AS INTEGER)),0)"
            + " FROM session_message WHERE type='assistant'"
            + " AND time_created >= \(startOfDayMs) \(freeFilter)"
        guard
            let row = sqlite3QueryOpenCode(sql: usageSql, db: url)?.first,
            row.count >= 3,
            let count = Int(row[0]),
            count > 0,
            let cost = Double(row[1]),
            let tokens = Int(row[2])
        else { return nil }
        let limitSql =
            "SELECT COUNT(*) FROM session_message WHERE type='assistant'"
            + " AND time_created >= \(startOfDayMs) AND data LIKE '%QuotaExceeded%'"
        let limited =
            (sqlite3QueryOpenCode(sql: limitSql, db: url)?.first?.first)
            .flatMap(Int.init) ?? 0 > 0
        let modelSql =
            "SELECT json_extract(data,'$.model.id') FROM session_message"
            + " WHERE type='assistant' AND time_created >= \(startOfDayMs) \(freeFilter)"
            + " ORDER BY time_created DESC LIMIT 1"
        let model = sqlite3QueryOpenCode(sql: modelSql, db: url)?.first?.first
        return QuotaState(
            limitReached: limited,
            model: model?.isEmpty == false ? model : nil,
            costTodayUSD: cost,
            tokensToday: tokens)
    }

    /// Per-model Go spend across the 5-hour, weekly, and monthly windows.
    /// Only `opencode-go` provider traffic counts; free-tier models are
    /// unlimited and tracked by the limit-wall state instead.
    static func goModelSpend(
        now: Date = Date(),
        home: String = NSHomeDirectory()
    ) -> [GoModelSpend] {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let fiveHMs = nowMs - 5 * 3_600 * 1_000
        let sevenDMs = nowMs - 7 * 86_400 * 1_000
        let thirtyDMs = nowMs - 30 * 86_400 * 1_000
        let sql =
            "SELECT json_extract(data,'$.model.id'),"
            + " COALESCE(SUM(CASE WHEN time_created >= \(fiveHMs)"
            + " THEN CAST(json_extract(data,'$.cost') AS REAL) ELSE 0 END),0),"
            + " COALESCE(SUM(CASE WHEN time_created >= \(sevenDMs)"
            + " THEN CAST(json_extract(data,'$.cost') AS REAL) ELSE 0 END),0),"
            + " COALESCE(SUM(CAST(json_extract(data,'$.cost') AS REAL)),0)"
            + " FROM session_message WHERE type='assistant'"
            + " AND json_extract(data,'$.model.providerID') = 'opencode-go'"
            + " AND time_created >= \(thirtyDMs)"
            + " GROUP BY 1"
        guard let rows = sqlite3QueryOpenCode(sql: sql, db: url) else { return [] }
        var result: [GoModelSpend] = []
        for row in rows {
            guard row.count >= 4, let modelID = row.first, !modelID.isEmpty else {
                continue
            }
            let fiveH = Double(row[1]) ?? 0
            let sevenD = Double(row[2]) ?? 0
            let thirtyD = Double(row[3]) ?? 0
            guard fiveH + sevenD + thirtyD > 0 else { continue }
            result.append(
                GoModelSpend(
                    modelID: modelID, spend5h: fiveH, spend7d: sevenD,
                    spend30d: thirtyD))
        }
        return result.sorted { $0.spend7d > $1.spend7d }
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
