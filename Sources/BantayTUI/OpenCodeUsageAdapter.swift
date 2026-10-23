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

    /// Bundled Go spend across windows, preferring opencode's own
    /// accounting (`opencode stats --json`). Falls back to ledger sums when
    /// the CLI is missing or slow. Windows are wall-clock ranges; Go's own
    /// 5h/weekly/monthly allowances cannot be read locally.
    struct GoBundledSpend: Equatable, Sendable {
        let spend5h: Double
        let spend7d: Double
        let spend30d: Double
    }

    static func goBundledSpend(
        now: Date = Date(),
        home: String = NSHomeDirectory(),
        opencodeBinary: String? = nil
    ) -> GoBundledSpend {
        GoBundledSpend(
            spend5h: goSpendSince(hours: 5, now: now, home: home),
            spend7d: statsGoCost(days: 7, opencodeBinary: opencodeBinary)
                ?? goSpendSince(hours: 24 * 7, now: now, home: home),
            spend30d: statsGoCost(days: 30, opencodeBinary: opencodeBinary)
                ?? goSpendSince(hours: 24 * 30, now: now, home: home))
    }

    /// Total opencode-go cost from opencode's own accounting for the range.
    /// Nil when the CLI is missing, slow, or unparsable so callers fall back
    /// to ledger sums.
    private static func statsGoCost(days: Int, opencodeBinary: String?) -> Double? {
        guard
            let output = runStatsJSON(days: days, opencodeBinary: opencodeBinary),
            let data = output.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = obj["models"] as? [[String: Any]]
        else { return nil }
        var total = 0.0
        var found = false
        for model in models {
            guard
                let info = model["model"] as? [String: Any],
                info["providerID"] as? String == "opencode-go",
                let cost = (model["cost"] as? NSNumber)?.doubleValue
            else { continue }
            found = true
            total += cost
        }
        return found ? total : nil
    }

    private static func runStatsJSON(days: Int, opencodeBinary: String?) -> String? {
        let binary =
            opencodeBinary
            ?? ["/opt/homebrew/bin/opencode", "\(NSHomeDirectory())/.local/bin/opencode"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "opencode"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [binary, "stats", "--json", "--days", "\(days)"]
        proc.standardOutput = Pipe()
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(8)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }
        guard proc.terminationStatus == 0,
            let pipe = proc.standardOutput as? Pipe
        else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func goSpendSince(hours: Double, now: Date, home: String) -> Double {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let sinceMs = Int64(now.timeIntervalSince1970 * 1000) - Int64(hours * 3_600 * 1_000)
        let sql =
            "SELECT COALESCE(SUM(CAST(json_extract(data,'$.cost') AS REAL)),0)"
            + " FROM session_message WHERE type='assistant'"
            + " AND json_extract(data,'$.model.providerID') = 'opencode-go'"
            + " AND time_created >= \(sinceMs)"
        guard let row = sqlite3QueryOpenCode(sql: sql, db: url)?.first,
            let first = row.first
        else { return 0 }
        return Double(first) ?? 0
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
