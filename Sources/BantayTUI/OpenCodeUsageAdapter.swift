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

    /// The SUM over every assistant message is the expensive part. The
    /// ledger revision (db + wal + shm mtime) is a cheap sentinel: reuse the
    /// last answer until the ledger actually moves.
    private final class SnapshotCache: @unchecked Sendable {
        struct Entry {
            let revision: UInt64
            let computedAt: Date
            let snapshot: UsageSnapshot?
        }

        static let shared = SnapshotCache()
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private var order: [String] = []

        func value(for key: String) -> Entry? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func store(_ entry: Entry, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            if entries[key] == nil { order.append(key) }
            entries[key] = entry
            while order.count > 16 {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
    }

    /// Quota rows change on a human cadence, not a poll cadence. Cache the
    /// expensive ledger queries and the `opencode stats` subprocesses so a
    /// 60-second probe does not repeat multi-second work every minute.
    private final class ProbeCache: @unchecked Sendable {
        struct QuotaEntry {
            let computedAt: Date
            let state: QuotaState?
        }

        struct BundledEntry {
            let computedAt: Date
            let value: GoBundledSpend
        }

        static let shared = ProbeCache()
        private let lock = NSLock()
        private var quota: [String: QuotaEntry] = [:]
        private var bundled: [String: BundledEntry] = [:]

        func quotaEntry(home: String) -> QuotaEntry? {
            lock.lock()
            defer { lock.unlock() }
            return quota[home]
        }

        func storeQuota(_ entry: QuotaEntry, home: String) {
            lock.lock()
            defer { lock.unlock() }
            quota[home] = entry
        }

        func bundledEntry(home: String) -> BundledEntry? {
            lock.lock()
            defer { lock.unlock() }
            return bundled[home]
        }

        func storeBundled(_ entry: BundledEntry, home: String) {
            lock.lock()
            defer { lock.unlock() }
            bundled[home] = entry
        }
    }

    private static let quotaStateCacheTTL: TimeInterval = 180
    private static let bundledSpendCacheTTL: TimeInterval = 300

    /// Aggregate usage over the last `window` seconds, keyed by message
    /// creation time (epoch ms). Returns nil when the DB is missing or empty.
    static func snapshot(
        since window: TimeInterval,
        now: Date = Date(),
        home: String = NSHomeDirectory(),
        maxAge: TimeInterval = 60
    ) -> UsageSnapshot? {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let cacheKey = "\(Int(window)):\(home)"
        let revision = ledgerRevision(home: home)
        if let cached = SnapshotCache.shared.value(for: cacheKey) {
            // A live ledger changes on nearly every poll, so revision equality
            // alone defeats the cache. Treat maxAge as a hard refresh floor;
            // completion paths pass 0 to force an exact read.
            if maxAge > 0, now.timeIntervalSince(cached.computedAt) < maxAge {
                return cached.snapshot
            }
            if cached.revision == revision {
                return cached.snapshot
            }
        }
        func cacheNil() {
            SnapshotCache.shared.store(
                SnapshotCache.Entry(revision: revision, computedAt: now, snapshot: nil),
                for: cacheKey)
        }
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
        else {
            cacheNil()
            return nil
        }
        guard input + output + reasoning + cacheRead + cacheWrite > 0 || cost > 0 else {
            cacheNil()
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
        SnapshotCache.shared.store(
            SnapshotCache.Entry(revision: revision, computedAt: now, snapshot: snapshot),
            for: cacheKey)
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
        let requestCount: Int
    }

    /// Go limit-wall state: walls hit by `opencode-go` traffic today and
    /// whether one is recent enough to still block (30 minutes).
    struct GoWallState: Equatable, Sendable {
        let wallsToday: Int
        let limitedNow: Bool
    }

    static func quotaState(
        now: Date = Date(),
        home: String = NSHomeDirectory()
    ) -> QuotaState? {
        if let cached = ProbeCache.shared.quotaEntry(home: home),
            now.timeIntervalSince(cached.computedAt) < quotaStateCacheTTL
        {
            return cached.state
        }
        let state = computeQuotaState(now: now, home: home)
        ProbeCache.shared.storeQuota(
            ProbeCache.QuotaEntry(computedAt: now, state: state), home: home)
        return state
    }

    private static func computeQuotaState(
        now: Date,
        home: String
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
            + " COALESCE(SUM(CAST(json_extract(data,'$.cost') AS REAL)),0)"
            + " FROM session_message WHERE type='assistant'"
            + " AND time_created >= \(startOfDayMs) \(freeFilter)"
        guard
            let row = sqlite3QueryOpenCode(sql: usageSql, db: url)?.first,
            row.count >= 2,
            let count = Int(row[0]),
            count > 0,
            let cost = Double(row[1])
        else { return nil }
        // Identity is the dominant model by message count, never the latest
        // row: one stray message must not rename the whole bucket.
        let modelSql =
            "SELECT json_extract(data,'$.model.id') FROM session_message"
            + " WHERE type='assistant' AND time_created >= \(startOfDayMs) \(freeFilter)"
            + " GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 1"
        let model = sqlite3QueryOpenCode(sql: modelSql, db: url)?.first?.first
        return QuotaState(
            limitReached: false,
            model: model?.isEmpty == false ? model : nil,
            costTodayUSD: cost,
            requestCount: count)
    }

    /// Go wall state scoped to `opencode-go` traffic only. Free-tier walls
    /// must never blame the Go row, and Go walls must never blame free tier.
    /// Walls are real provider errors (`finish='error'` carrying the quota
    /// error): a blind `data LIKE` also matches tool inputs, so even a debug
    /// query mentioning the string would fake a wall.
    static func goWallState(
        now: Date = Date(),
        home: String = NSHomeDirectory()
    ) -> GoWallState? {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let calendar = Calendar.current
        let startOfDayMs = Int64(
            calendar.startOfDay(for: now).timeIntervalSince1970 * 1000)
        let recentMs = nowMs - 30 * 60 * 1_000
        let sql =
            "SELECT COUNT(*), COALESCE(MAX(time_created),0)"
            + " FROM session_message WHERE type='assistant'"
            + " AND json_extract(data,'$.model.providerID') = 'opencode-go'"
            + " AND time_created >= \(startOfDayMs)"
            + " AND json_extract(data,'$.finish') = 'error'"
            + " AND LOWER(COALESCE(json_extract(data,'$.error.message'),''))"
            + " LIKE '%quota%exceed%'"
        guard
            let row = sqlite3QueryOpenCode(sql: sql, db: url)?.first,
            row.count >= 2,
            let walls = Int(row[0]),
            let lastWall = Int(row[1])
        else { return nil }
        guard walls > 0 else {
            return GoWallState(wallsToday: 0, limitedNow: false)
        }
        return GoWallState(
            wallsToday: walls,
            limitedNow: Int64(lastWall) >= recentMs)
    }

    /// Bundled Go spend across windows, preferring opencode's own
    /// accounting (`opencode stats --json`). Falls back to ledger sums when
    /// the CLI is missing or slow. Windows are wall-clock ranges; Go's own
    /// 5h/weekly/monthly allowances cannot be read locally.
    struct GoBundledSpend: Equatable, Sendable {
        let spend5h: Double
        let spend7d: Double
        let spend30d: Double
        let oldest5hMs: Int64?
        let oldest7dMs: Int64?
        let oldest30dMs: Int64?
    }

    /// One Go allowance window: wall-clock length, fraction of the monthly
    /// allowance, measured spend, and oldest spend timestamp for reset math.
    struct GoWindowUsage: Equatable, Sendable {
        let label: String
        let lengthMs: Int64
        let fraction: Double
        let spend: Double
        let oldestMs: Int64?
    }

    /// The tightest allowance window: highest spend relative to its
    /// allowance. Returns spend, allowance, percent used, label, and reset
    /// date (oldest in-window spend aging out, nil when the window is empty).
    static func tightestAllowanceWindow(
        usages: [GoWindowUsage], monthlyAllowance: Double, nowMs: Int64
    ) -> (spend: Double, allowance: Double, percentUsed: Double, label: String, resetsAt: Date?) {
        var bestSpend = 0.0
        var bestAllowance = monthlyAllowance
        var bestLabel = "monthly"
        var bestRatio = 0.0
        var bestResetsAt: Date? = nil
        for usage in usages {
            let allowance = max(monthlyAllowance * usage.fraction, 0.01)
            let ratio = usage.spend / allowance
            if ratio > bestRatio {
                bestRatio = ratio
                bestSpend = usage.spend
                bestAllowance = allowance
                bestLabel = usage.label
                if let oldest = usage.oldestMs {
                    bestResetsAt = Date(
                        timeIntervalSince1970: Double(oldest + usage.lengthMs) / 1000.0)
                } else {
                    bestResetsAt = nil
                }
            }
        }
        _ = nowMs
        return (
            spend: bestSpend, allowance: bestAllowance,
            percentUsed: min(max(bestRatio * 100, 0), 100),
            label: bestLabel, resetsAt: bestResetsAt
        )
    }

    static func goBundledSpend(
        now: Date = Date(),
        home: String = NSHomeDirectory(),
        opencodeBinary: String? = nil
    ) -> GoBundledSpend {
        if let cached = ProbeCache.shared.bundledEntry(home: home),
            now.timeIntervalSince(cached.computedAt) < bundledSpendCacheTTL
        {
            return cached.value
        }
        let value = computeGoBundledSpend(
            now: now, home: home, opencodeBinary: opencodeBinary)
        ProbeCache.shared.storeBundled(
            ProbeCache.BundledEntry(computedAt: now, value: value), home: home)
        return value
    }

    private static func computeGoBundledSpend(
        now: Date,
        home: String,
        opencodeBinary: String?
    ) -> GoBundledSpend {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        return GoBundledSpend(
            spend5h: goSpendSince(hours: 5, now: now, home: home),
            spend7d: statsGoCost(days: 7, opencodeBinary: opencodeBinary)
                ?? goSpendSince(hours: 24 * 7, now: now, home: home),
            spend30d: statsGoCost(days: 30, opencodeBinary: opencodeBinary)
                ?? goSpendSince(hours: 24 * 30, now: now, home: home),
            oldest5hMs: goOldestSince(hours: 5, nowMs: nowMs, home: home),
            oldest7dMs: goOldestSince(hours: 24 * 7, nowMs: nowMs, home: home),
            oldest30dMs: goOldestSince(hours: 24 * 30, nowMs: nowMs, home: home))
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

    private static func goOldestSince(hours: Double, nowMs: Int64, home: String) -> Int64? {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let sinceMs = nowMs - Int64(hours * 3_600 * 1_000)
        let sql =
            "SELECT COALESCE(MIN(time_created),0)"
            + " FROM session_message WHERE type='assistant'"
            + " AND json_extract(data,'$.model.providerID') = 'opencode-go'"
            + " AND time_created >= \(sinceMs)"
        guard let row = sqlite3QueryOpenCode(sql: sql, db: url)?.first,
            let first = row.first,
            let oldest = Int64(first),
            oldest > 0
        else { return nil }
        return oldest
    }

    /// Lifetime ledger totals from the pre-aggregated `session_v2` row
    /// sums — one cheap query, no message scan. The authoritative answer
    /// for "how much have I ever spent", matching `opencode stats`.
    struct LifetimeTotals: Equatable, Sendable {
        let tokens: Int
        let cost: Double
        let sessions: Int
    }

    static func lifetimeTotals(
        home: String = NSHomeDirectory()
    ) -> LifetimeTotals? {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let sql =
            "SELECT COALESCE(SUM(tokens_input+tokens_output+tokens_reasoning"
            + "+tokens_cache_read+tokens_cache_write),0),"
            + " COALESCE(SUM(cost),0), COUNT(*)"
            + " FROM session_v2"
        guard
            let row = sqlite3QueryOpenCode(sql: sql, db: url)?.first,
            row.count >= 3,
            let tokens = Int(row[0]),
            let cost = Double(row[1]),
            let sessions = Int(row[2]),
            sessions > 0
        else { return nil }
        return LifetimeTotals(tokens: tokens, cost: cost, sessions: sessions)
    }

    /// Lifetime meter strictly before a moment: the same message-table sums
    /// as `snapshot`, bounded by `time_created`. Session baselines must
    /// describe the world when work STARTED, not when the progress event was
    /// processed — otherwise short sessions meter ~0. Nil when the ledger is
    /// missing or holds no earlier messages.
    static func meterAsOf(
        beforeMs: Int64, home: String = NSHomeDirectory()
    ) -> (tokens: Int, cost: Double)? {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let sql =
            "SELECT COALESCE(SUM(CAST(json_extract(data,'$.tokens.input') AS INTEGER)"
            + "+CAST(json_extract(data,'$.tokens.output') AS INTEGER)"
            + "+CAST(json_extract(data,'$.tokens.reasoning') AS INTEGER)"
            + "+CAST(json_extract(data,'$.tokens.cache.read') AS INTEGER)"
            + "+CAST(json_extract(data,'$.tokens.cache.write') AS INTEGER)),0),"
            + " COALESCE(SUM(CAST(json_extract(data,'$.cost') AS REAL)),0)"
            + " FROM session_message WHERE type='assistant'"
            + " AND time_created < \(beforeMs)"
        guard
            let row = sqlite3QueryOpenCode(sql: sql, db: url)?.first,
            row.count >= 2,
            let tokens = Int(row[0]),
            let cost = Double(row[1]),
            tokens > 0 || cost > 0
        else { return nil }
        return (tokens, cost)
    }

    /// Per-day message aggregates, newest first, for streaks, active-day
    /// counts, and windowed scopes. Day boundaries use local time, matching
    /// every contribution-grid convention.
    struct DayBucket: Equatable, Sendable {
        let dayStart: Date
        let tokens: Int
        let cost: Double
        let messages: Int
    }

    static func dailyBuckets(
        days: Int, now: Date = Date(), home: String = NSHomeDirectory()
    ) -> [DayBucket] {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let calendar = Calendar.current
        guard
            let startDay = calendar.date(
                byAdding: .day, value: -max(days - 1, 0),
                to: calendar.startOfDay(for: now))
        else { return [] }
        let sinceMs = Int64(startDay.timeIntervalSince1970 * 1000)
        let sql =
            "SELECT date(time_created/1000,'unixepoch','localtime'),"
            + " COALESCE(SUM(CAST(json_extract(data,'$.tokens.input') AS INTEGER)"
            + "+CAST(json_extract(data,'$.tokens.output') AS INTEGER)"
            + "+CAST(json_extract(data,'$.tokens.reasoning') AS INTEGER)"
            + "+CAST(json_extract(data,'$.tokens.cache.read') AS INTEGER)"
            + "+CAST(json_extract(data,'$.tokens.cache.write') AS INTEGER)),0),"
            + " COALESCE(SUM(CAST(json_extract(data,'$.cost') AS REAL)),0),"
            + " COUNT(*)"
            + " FROM session_message WHERE type='assistant'"
            + " AND time_created >= \(sinceMs)"
            + " GROUP BY 1 ORDER BY 1 DESC"
        guard let rows = sqlite3QueryOpenCode(sql: sql, db: url) else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        var buckets: [DayBucket] = []
        for row in rows {
            guard row.count >= 4,
                let day = formatter.date(from: row[0]),
                let tokens = Int(row[1]),
                let cost = Double(row[2]),
                let messages = Int(row[3])
            else {
                continue
            }
            buckets.append(
                DayBucket(
                    dayStart: calendar.startOfDay(for: day), tokens: tokens,
                    cost: cost, messages: messages))
        }
        return buckets
    }

    /// Revision sentinel for the ledger files (db + WAL + SHM). Refresh
    /// cached lifetime queries only when this moves; polling a SUM every
    /// few seconds would waste the exactness it buys.
    static func ledgerRevision(home: String = NSHomeDirectory()) -> UInt64 {
        let base = databaseURL(home: home).path
        var latest: UInt64 = 0
        for path in [base, base + "-wal", base + "-shm"] {
            guard
                let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                let date = attrs[.modificationDate] as? Date
            else {
                continue
            }
            latest = max(latest, UInt64(date.timeIntervalSince1970))
        }
        return latest
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
