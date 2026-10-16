import Foundation
import SQLite3

/// Deep telemetry metrics parsed directly from OpenAI Codex's local SQLite database.
public struct CodexDeepTelemetry: Equatable, Sendable {
    public var totalTokensUsed: Int
    public var todayTokensUsed: Int
    public var activeThreadCount: Int
    public var latestThreadTitle: String?
    public var latestModel: String?
    public var lastUpdatedAt: Date?
    public var estimatedCostUSD: Double

    public init(
        totalTokensUsed: Int = 0,
        todayTokensUsed: Int = 0,
        activeThreadCount: Int = 0,
        latestThreadTitle: String? = nil,
        latestModel: String? = nil,
        lastUpdatedAt: Date? = nil,
        estimatedCostUSD: Double = 0.0
    ) {
        self.totalTokensUsed = totalTokensUsed
        self.todayTokensUsed = todayTokensUsed
        self.activeThreadCount = activeThreadCount
        self.latestThreadTitle = latestThreadTitle
        self.latestModel = latestModel
        self.lastUpdatedAt = lastUpdatedAt
        self.estimatedCostUSD = estimatedCostUSD
    }
}

/// Universal adapter reading OpenAI Codex thread tokens from `~/.codex/state_5.sqlite`.
public enum CodexUsageAdapter: Sendable {
    public static func databaseURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: "\(home)/.codex/state_5.sqlite")
    }

    /// Whether Codex's SQLite state database is present on disk.
    public static func detect(home: String = NSHomeDirectory()) -> Bool {
        FileManager.default.fileExists(atPath: databaseURL(home: home).path)
    }

    /// Deep inspection of Codex `threads` table for real-time token tracking.
    public static func deepTelemetry(home: String = NSHomeDirectory()) -> CodexDeepTelemetry? {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var telemetry = CodexDeepTelemetry()

        // 1. Total tokens and thread count across all threads
        let totalSql = "SELECT COALESCE(SUM(tokens_used), 0), COUNT(id) FROM threads;"
        if let totalRow = sqlite3Query(sql: totalSql, db: url)?.first {
            telemetry.totalTokensUsed = Int(totalRow[safe: 0] ?? "0") ?? 0
            telemetry.activeThreadCount = Int(totalRow[safe: 1] ?? "0") ?? 0
        }

        // 2. Today's tokens (since start of current calendar day)
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let startOfDayMs = Int64(startOfDay.timeIntervalSince1970 * 1000)
        let todaySql =
            "SELECT COALESCE(SUM(tokens_used), 0) FROM threads WHERE updated_at_ms >= \(startOfDayMs);"
        if let todayRow = sqlite3Query(sql: todaySql, db: url)?.first {
            telemetry.todayTokensUsed = Int(todayRow[safe: 0] ?? "0") ?? 0
        }

        // 3. Latest thread details
        let latestSql =
            "SELECT title, model, updated_at_ms FROM threads ORDER BY updated_at_ms DESC LIMIT 1;"
        if let latestRow = sqlite3Query(sql: latestSql, db: url)?.first {
            let title = latestRow[safe: 0]
            telemetry.latestThreadTitle = (title?.isEmpty == false) ? title : nil
            let model = latestRow[safe: 1]
            telemetry.latestModel = (model?.isEmpty == false) ? model : nil
            if let msStr = latestRow[safe: 2], let ms = Int64(msStr), ms > 0 {
                telemetry.lastUpdatedAt = Date(timeIntervalSince1970: Double(ms) / 1000.0)
            }
        }

        // Standard estimate: $3 per 1M tokens for Codex/GPT-4o class reasoning
        let tokensForCost =
            telemetry.todayTokensUsed > 0 ? telemetry.todayTokensUsed : telemetry.totalTokensUsed
        telemetry.estimatedCostUSD = (Double(tokensForCost) / 1_000_000.0) * 3.0

        return telemetry
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
            "SELECT COALESCE(SUM(tokens_used), 0) FROM threads WHERE updated_at_ms >= \(sinceMs);"

        guard let row = sqlite3Query(sql: sql, db: url)?.first,
            let tokens = Int(row.first ?? "0"),
            tokens > 0
        else {
            return nil
        }

        let cost = (Double(tokens) / 1_000_000.0) * 3.0
        var snapshot = UsageSnapshot()
        snapshot.inputTokens = Int(Double(tokens) * 0.75)
        snapshot.outputTokens = Int(Double(tokens) * 0.25)
        snapshot.costUSD = cost
        snapshot.costBySource["codex"] = cost
        return snapshot
    }
}

/// Deep telemetry metrics parsed directly from Cursor's local SQLite database.
public struct CursorDeepTelemetry: Equatable, Sendable {
    public var composerSuggestedLines: Int
    public var composerAcceptedLines: Int
    public var tabSuggestedLines: Int
    public var tabAcceptedLines: Int
    public var contextUsagePercent: Double?
    public var totalLinesAdded: Int
    public var totalLinesRemoved: Int
    public var filesChangedCount: Int
    public var activeSessionName: String?
    public var unifiedMode: String?
    public var generationsCount: Int
    public var estimatedTokens: Int
    public var estimatedCostUSD: Double
    public var fastRequestsRemaining: Int

    public init(
        composerSuggestedLines: Int = 0,
        composerAcceptedLines: Int = 0,
        tabSuggestedLines: Int = 0,
        tabAcceptedLines: Int = 0,
        contextUsagePercent: Double? = nil,
        totalLinesAdded: Int = 0,
        totalLinesRemoved: Int = 0,
        filesChangedCount: Int = 0,
        activeSessionName: String? = nil,
        unifiedMode: String? = nil,
        generationsCount: Int = 0,
        estimatedTokens: Int = 0,
        estimatedCostUSD: Double = 0.0,
        fastRequestsRemaining: Int = 500
    ) {
        self.composerSuggestedLines = composerSuggestedLines
        self.composerAcceptedLines = composerAcceptedLines
        self.tabSuggestedLines = tabSuggestedLines
        self.tabAcceptedLines = tabAcceptedLines
        self.contextUsagePercent = contextUsagePercent
        self.totalLinesAdded = totalLinesAdded
        self.totalLinesRemoved = totalLinesRemoved
        self.filesChangedCount = filesChangedCount
        self.activeSessionName = activeSessionName
        self.unifiedMode = unifiedMode
        self.generationsCount = generationsCount
        self.estimatedTokens = estimatedTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.fastRequestsRemaining = fastRequestsRemaining
    }
}

/// Universal adapter reading Cursor AI daily statistics and composer data from `state.vscdb`.
public enum CursorUsageAdapter: Sendable {
    public static func databaseURL(home: String = NSHomeDirectory()) -> URL {
        URL(
            fileURLWithPath:
                "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
    }

    /// Whether Cursor's SQLite state database is present on disk.
    public static func detect(home: String = NSHomeDirectory()) -> Bool {
        FileManager.default.fileExists(atPath: databaseURL(home: home).path)
    }

    /// Deep inspection of Cursor's `state.vscdb` ItemTable for lines, context%, and composer sessions.
    public static func deepTelemetry(home: String = NSHomeDirectory()) -> CursorDeepTelemetry? {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var telemetry = CursorDeepTelemetry()

        // 1. Query daily stats JSON line records from ItemTable
        let statsSql =
            "SELECT CAST(value AS TEXT) FROM ItemTable "
            + "WHERE key LIKE 'aiCodeTracking.dailyStats%' ORDER BY key DESC LIMIT 1;"
        if let row = sqlite3Query(sql: statsSql, db: url)?.first,
            let jsonStr = row.first,
            let data = jsonStr.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            telemetry.composerSuggestedLines =
                (obj["composerSuggestedLines"] as? NSNumber)?.intValue ?? 0
            telemetry.composerAcceptedLines =
                (obj["composerAcceptedLines"] as? NSNumber)?.intValue ?? 0
            telemetry.tabSuggestedLines = (obj["tabSuggestedLines"] as? NSNumber)?.intValue ?? 0
            telemetry.tabAcceptedLines = (obj["tabAcceptedLines"] as? NSNumber)?.intValue ?? 0
        }

        // 2. Query composer headers for active sessions, context %, and file diff metrics
        let composerSql =
            "SELECT CAST(value AS TEXT) FROM ItemTable WHERE key = 'composer.composerHeaders';"
        if let row = sqlite3Query(sql: composerSql, db: url)?.first,
            let jsonStr = row.first,
            let data = jsonStr.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let allComposers = root["allComposers"] as? [[String: Any]]
        {
            // Find the most recently updated composer session
            let active = allComposers.max { a, b in
                let aTime = (a["lastUpdatedAt"] as? NSNumber)?.int64Value ?? 0
                let bTime = (b["lastUpdatedAt"] as? NSNumber)?.int64Value ?? 0
                return aTime < bTime
            }

            if let active {
                if let ctx = (active["contextUsagePercent"] as? NSNumber)?.doubleValue {
                    telemetry.contextUsagePercent = min(max(ctx, 0.0), 100.0)
                }
                telemetry.totalLinesAdded = (active["totalLinesAdded"] as? NSNumber)?.intValue ?? 0
                telemetry.totalLinesRemoved =
                    (active["totalLinesRemoved"] as? NSNumber)?.intValue ?? 0
                telemetry.filesChangedCount =
                    (active["filesChangedCount"] as? NSNumber)?.intValue ?? 0
                telemetry.activeSessionName = active["name"] as? String
                telemetry.unifiedMode = active["unifiedMode"] as? String
            }
        }

        // 3. Estimate tokens, cost, and fast requests remaining
        let totalLines =
            telemetry.composerSuggestedLines + telemetry.composerAcceptedLines
            + telemetry.tabAcceptedLines + telemetry.totalLinesAdded
        telemetry.estimatedTokens = totalLines * 25
        telemetry.estimatedCostUSD = (Double(telemetry.estimatedTokens) / 1_000_000.0) * 3.5

        // Assume nominal 500 fast requests pool
        let requestsUsed = min(500, max(0, totalLines / 50))
        telemetry.fastRequestsRemaining = max(0, 500 - requestsUsed)

        return telemetry
    }

    /// Query daily stats JSON line records from Cursor's ItemTable.
    static func snapshot(
        now: Date = Date(),
        home: String = NSHomeDirectory()
    ) -> UsageSnapshot? {
        guard let telemetry = deepTelemetry(home: home), telemetry.estimatedTokens > 0 else {
            return nil
        }
        var snapshot = UsageSnapshot()
        snapshot.inputTokens = Int(Double(telemetry.estimatedTokens) * 0.6)
        snapshot.outputTokens = Int(Double(telemetry.estimatedTokens) * 0.4)
        snapshot.costUSD = telemetry.estimatedCostUSD
        snapshot.costBySource["cursor"] = telemetry.estimatedCostUSD
        return snapshot
    }
}

/// Real-time rate limits ingested from Claude Code's `statusLine` hook or local state.
public struct ClaudeRateLimits: Equatable, Sendable, Codable {
    public struct Window: Equatable, Sendable, Codable {
        public var usedPercentage: Double
        public var resetsAt: Date?

        public init(usedPercentage: Double = 0.0, resetsAt: Date? = nil) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }
    }

    public var fiveHour: Window?
    public var sevenDay: Window?
    public var lastUpdated: Date

    public init(
        fiveHour: Window? = nil,
        sevenDay: Window? = nil,
        lastUpdated: Date = Date()
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.lastUpdated = lastUpdated
    }
}

/// Adapter for real-time Claude Code statusLine and local rate limit telemetry.
public enum ClaudeUsageAdapter: Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _cachedLimits: ClaudeRateLimits?

    public static var cachedLimits: ClaudeRateLimits? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _cachedLimits
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _cachedLimits = newValue
        }
    }

    /// Parses rate limit JSON payload from Claude Code statusLine or file export.
    public static func parseRateLimitsJSON(_ data: Data) -> ClaudeRateLimits? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let limitsObj =
            (obj["rate_limits"] as? [String: Any])
            ?? (obj["rateLimits"] as? [String: Any])
            ?? obj

        func parseWindow(_ raw: Any?) -> ClaudeRateLimits.Window? {
            guard let dict = raw as? [String: Any] else { return nil }
            let used =
                (dict["used_percentage"] as? NSNumber)?.doubleValue
                ?? (dict["usedPercentage"] as? NSNumber)?.doubleValue
                ?? (dict["used"] as? NSNumber)?.doubleValue
                ?? 0.0

            var resetsAt: Date?
            if let num = (dict["resets_at"] as? NSNumber)?.doubleValue
                ?? (dict["resetsAt"] as? NSNumber)?.doubleValue
                ?? (dict["reset"] as? NSNumber)?.doubleValue
            {
                if num > 1_000_000_000_000 {
                    resetsAt = Date(timeIntervalSince1970: num / 1000.0)
                } else if num > 1_000_000_000 {
                    resetsAt = Date(timeIntervalSince1970: num)
                }
            } else if let str = dict["resets_at"] as? String
                ?? dict["resetsAt"] as? String
            {
                if let sec = Double(str) {
                    resetsAt = Date(timeIntervalSince1970: sec)
                } else {
                    let iso = ISO8601DateFormatter()
                    resetsAt = iso.date(from: str)
                }
            }

            return ClaudeRateLimits.Window(usedPercentage: used, resetsAt: resetsAt)
        }

        let fiveH =
            parseWindow(limitsObj["five_hour"])
            ?? parseWindow(limitsObj["fiveHour"])
            ?? parseWindow(limitsObj["5h"])
        let sevenD =
            parseWindow(limitsObj["seven_day"])
            ?? parseWindow(limitsObj["sevenDay"])
            ?? parseWindow(limitsObj["7d"])

        guard fiveH != nil || sevenD != nil else { return nil }
        return ClaudeRateLimits(fiveHour: fiveH, sevenDay: sevenD, lastUpdated: Date())
    }

    /// Records payload directly from EventIngestServer /telemetry/claude route.
    @discardableResult
    public static func record(jsonString: String) -> ClaudeRateLimits? {
        guard let data = jsonString.data(using: .utf8),
            let limits = parseRateLimitsJSON(data)
        else {
            return nil
        }
        cachedLimits = limits
        return limits
    }

    /// Reads cached rate limits from ~/.claude statusline files if present.
    public static func readFromDisk(home: String = NSHomeDirectory()) -> ClaudeRateLimits? {
        let candidatePaths = [
            "\(home)/.claude/rate_limits.json",
            "\(home)/.claude/statusline-output.json",
            "\(home)/.claude/telemetry.json",
        ]
        for path in candidatePaths {
            if let data = FileManager.default.contents(atPath: path),
                let limits = parseRateLimitsJSON(data)
            {
                cachedLimits = limits
                return limits
            }
        }
        return nil
    }

    /// Generates high-fidelity ProviderQuota using live statusLine rate limits.
    public static func quota(home: String = NSHomeDirectory()) -> ProviderQuota? {
        guard let limits = cachedLimits ?? readFromDisk(home: home) else {
            return nil
        }
        let usedPct = limits.fiveHour?.usedPercentage ?? limits.sevenDay?.usedPercentage ?? 0.0
        let remainingPct = max(0.0, min(100.0, 100.0 - usedPct))
        let resetsAt = limits.fiveHour?.resetsAt ?? limits.sevenDay?.resetsAt
        let tier = limits.sevenDay != nil ? "Pro / Max" : "Pro Plan"
        let usedStr = String(format: "%.0f%% used", usedPct)

        return ProviderQuota(
            provider: "Claude Code",
            remainingPercent: remainingPct,
            resetHint: "5h rolling window",
            tier: tier,
            usedDisplay: usedStr,
            totalDisplay: "5h Window",
            resetsAt: resetsAt
        )
    }
}

/// Universal adapter probing OpenRouter BYOK key metadata, usage, and credit limits.
public enum OpenRouterUsageAdapter: Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _cachedQuota: ProviderQuota?

    public static var cachedQuota: ProviderQuota? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _cachedQuota
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _cachedQuota = newValue
        }
    }

    /// Detects presence of OpenRouter API key in environment or local config files.
    public static func detect(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> Bool {
        if let key = env["OPENROUTER_API_KEY"], !key.isEmpty { return true }
        let paths = [
            "\(home)/.openrouter/config.json",
            "\(home)/.config/openrouter/key",
            "\(home)/.openrouter/key",
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Parses OpenRouter /api/v1/key response payload into ProviderQuota.
    public static func parseKeyResponse(_ data: Data) -> ProviderQuota? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let dataObj = (obj["data"] as? [String: Any]) ?? obj
        let usage = (dataObj["usage"] as? NSNumber)?.doubleValue ?? 0.0
        let limit = (dataObj["limit"] as? NSNumber)?.doubleValue
        let isFreeTier = (dataObj["is_free_tier"] as? Bool) ?? false

        let remainingPct: Double
        let totalStr: String
        if let limit = limit, limit > 0 {
            remainingPct = max(0.0, min(100.0, ((limit - usage) / limit) * 100.0))
            totalStr = String(format: "$%.2f cap", limit)
        } else {
            remainingPct = 100.0
            totalStr = "PayG"
        }

        let tierStr = isFreeTier ? "Free Tier" : "BYOK"
        let usedStr = String(format: "$%.2f used", usage)

        return ProviderQuota(
            provider: "OpenRouter",
            remainingPercent: remainingPct,
            resetHint: "Monthly credit limit",
            tier: tierStr,
            usedDisplay: usedStr,
            totalDisplay: totalStr,
            resetsAt: nil
        )
    }
}

/// Universal adapter probing local Ollama models and VRAM limits.
public enum OllamaUsageAdapter: Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _cachedQuota: ProviderQuota?

    public static var cachedQuota: ProviderQuota? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _cachedQuota
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _cachedQuota = newValue
        }
    }

    /// Whether local Ollama service is configured or running.
    public static func detect(home: String = NSHomeDirectory()) -> Bool {
        if FileManager.default.fileExists(atPath: "\(home)/.ollama") { return true }
        if FileManager.default.fileExists(atPath: "/usr/local/bin/ollama")
            || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ollama")
        {
            return true
        }
        return false
    }

    /// Parses Ollama /api/ps response payload into ProviderQuota.
    public static func parsePsResponse(_ data: Data) -> ProviderQuota? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let models = (obj["models"] as? [[String: Any]]) ?? []
        let modelNames = models.compactMap { $0["name"] as? String ?? $0["model"] as? String }
        let count = models.count
        let usedDisplay =
            count > 0
            ? "\(count) running (\(modelNames.prefix(2).joined(separator: ", ")))"
            : "Idle"

        return ProviderQuota(
            provider: "Ollama",
            remainingPercent: 100.0,
            resetHint: "Unlimited (Local)",
            tier: "Local Models",
            usedDisplay: usedDisplay,
            totalDisplay: "Local VRAM",
            resetsAt: nil
        )
    }
}

// ponytail: single shared SQLite query helper with immutable zero-locking URI
private func sqlite3Query(sql: String, db: URL) -> [[String]]? {
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

extension Array {
    fileprivate subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
