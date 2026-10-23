import Foundation

/// Provider quota status representation from `quota-axi` or local usage engines.
public struct ProviderQuota: Identifiable, Codable, Equatable, Sendable {
    public var id: String {
        let lower = provider.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("claude") || lower.contains("anthropic") { return "claude" }
        if lower.contains("codex") || lower.contains("openai") { return "codex" }
        if lower.contains("cursor") { return "cursor" }
        if lower.contains("cloud") { return "cloudcode" }
        if lower.contains("antigravity") || lower.contains("agy") || lower.contains("gemini") {
            return "antigravity"
        }
        if lower.contains("windsurf") || lower.contains("cascade") { return "windsurf" }
        if lower.contains("kilo") { return "kilo" }
        if lower.contains("openrouter") { return "openrouter" }
        if lower.contains("ollama") { return "ollama" }
        return lower
    }
    public var provider: String
    public var remainingPercent: Double
    public var resetHint: String
    public var tier: String
    public var usedDisplay: String
    public var totalDisplay: String
    public var burnRateTPM: Double
    public var hoursRemaining: Double?
    public var resetsAt: Date?
    public var isCooldown: Bool
    /// True when the provider reported a hard limit wall (e.g. opencode
    /// free-tier QuotaExceeded). Renders as a red limit state, not a bar.
    public var limitReached: Bool
    /// True for rows with no meaningful percentage: computed estimates and
    /// spend-only rows without a quota cap. The UI labels them and hides
    /// the progress bar.
    public var isEstimated: Bool
    /// True when the row reports spend without a quota cap, so the progress
    /// bar would be meaningless. The row renders text only.
    public var hidesProgress: Bool
    public var isWarning: Bool { remainingPercent <= 20.0 }
    public var isCritical: Bool { remainingPercent <= 5.0 || isCooldown || limitReached }

    public init(
        provider: String,
        remainingPercent: Double,
        resetHint: String = "24h",
        tier: String = "Pro",
        usedDisplay: String = "",
        totalDisplay: String = "",
        burnRateTPM: Double = 0.0,
        hoursRemaining: Double? = nil,
        resetsAt: Date? = nil,
        isCooldown: Bool = false,
        limitReached: Bool = false,
        isEstimated: Bool = false,
        hidesProgress: Bool = false
    ) {
        self.provider = provider
        self.remainingPercent = min(max(remainingPercent, 0.0), 100.0)
        self.resetHint = resetHint
        self.tier = tier
        self.usedDisplay = usedDisplay
        self.totalDisplay = totalDisplay
        self.burnRateTPM = burnRateTPM
        self.hoursRemaining = hoursRemaining
        self.resetsAt = resetsAt
        self.isCooldown = isCooldown
        self.limitReached = limitReached
        self.isEstimated = isEstimated
        self.hidesProgress = hidesProgress
    }

    /// Convenience initializer for generated/estimated quota rows.
    public init(
        isEstimated: Bool,
        provider: String,
        remainingPercent: Double,
        resetHint: String = "24h",
        tier: String = "Pro",
        usedDisplay: String = "",
        totalDisplay: String = "",
        burnRateTPM: Double = 0.0,
        hoursRemaining: Double? = nil,
        resetsAt: Date? = nil,
        isCooldown: Bool = false,
        limitReached: Bool = false,
        hidesProgress: Bool = false
    ) {
        self.init(
            provider: provider,
            remainingPercent: remainingPercent,
            resetHint: resetHint,
            tier: tier,
            usedDisplay: usedDisplay,
            totalDisplay: totalDisplay,
            burnRateTPM: burnRateTPM,
            hoursRemaining: hoursRemaining,
            resetsAt: resetsAt,
            isCooldown: isCooldown,
            limitReached: limitReached,
            isEstimated: isEstimated,
            hidesProgress: hidesProgress)
    }

    /// Formats dynamic live countdown if resetsAt is present, otherwise falls back to static resetHint.
    public func dynamicResetDescription(now: Date = Date()) -> String {
        guard let resetsAt else { return resetHint }
        let diff = resetsAt.timeIntervalSince(now)
        if diff <= 0 {
            return "Resets now"
        }
        let totalMinutes = Int(diff / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(max(1, minutes))m"
        }
    }
}

/// Service that queries `quota-axi --json` or computes transcript-backed quota metrics.
public final class QuotaAxiTracker: Sendable {
    public static let shared = QuotaAxiTracker()

    public init() {}

    /// Parse quota-axi JSON string output.
    public static func parseQuotaJSON(_ jsonString: String) -> [ProviderQuota] {
        guard let data = jsonString.data(using: .utf8) else { return [] }
        struct RawQuotaItem: Decodable {
            let provider: String?
            let remaining: Double?
            let remainingPercent: Double?
            let reset: String?
            let tier: String?
            let used: String?
            let total: String?
        }

        do {
            let items = try JSONDecoder().decode([RawQuotaItem].self, from: data)
            return items.compactMap { item in
                guard let provider = item.provider else { return nil }
                let percent = item.remainingPercent ?? item.remaining ?? 100.0
                return ProviderQuota(
                    provider: provider,
                    remainingPercent: percent,
                    resetHint: item.reset ?? "24h",
                    tier: item.tier ?? "Standard",
                    usedDisplay: item.used ?? "",
                    totalDisplay: item.total ?? ""
                )
            }
        } catch {
            return []
        }
    }

    /// Probes live quotas. Returns ONLY provider-reported rows: quota-axi
    /// output, Claude rate limits, or cached OpenRouter/Ollama quotas.
    /// Providers without a quota source never appear, no matter which
    /// directories exist on disk or which agents are running. Directory
    /// presence is not usage, and a budget ratio is not a quota.
    public static func probeLiveQuotas(
        activeProviders: [String],
        costUSD: Double,
        budgetUSD: Double,
        burnRateTPM: Double = 0.0,
        home: String = NSHomeDirectory(),
        goMonthlyAllowanceUSD: Double = 60
    ) -> [ProviderQuota] {
        // 1. Try quota-axi CLI if installed
        let candidateBins = [
            "/opt/homebrew/bin/quota-axi",
            "/usr/local/bin/quota-axi",
            home + "/.cargo/bin/quota-axi",
            home + "/.local/bin/quota-axi",
        ]
        for bin in candidateBins {
            if FileManager.default.isExecutableFile(atPath: bin) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: bin)
                proc.arguments = ["--json"]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                if (try? proc.run()) != nil {
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        if let output = String(data: data, encoding: .utf8),
                            !output.isEmpty
                        {
                            let parsed = parseQuotaJSON(output)
                            if !parsed.isEmpty { return parsed }
                        }
                    }
                }
            }
        }

        // 2. Provider-reported quotas only. Recognize which providers could
        // have data, but only emit rows backed by a real quota source.
        var results: [ProviderQuota] = []
        var recognized: Set<String> = []

        // Normalize active provider names
        for raw in activeProviders {
            let clean = cleanProviderName(raw)
            recognized.insert(clean)
        }

        // Auto-detect providers present on this system
        let fs = FileManager.default
        if fs.fileExists(atPath: home + "/.claude") { recognized.insert("claude") }
        if fs.fileExists(atPath: home + "/.codex")
            || fs.fileExists(atPath: home + "/.config/codex")
        {
            recognized.insert("codex")
        }
        if fs.fileExists(atPath: home + "/Library/Application Support/Cursor")
            || fs.fileExists(atPath: home + "/.cursor")
        {
            recognized.insert("cursor")
        }
        if fs.fileExists(atPath: home + "/.cloudcode")
            || fs.fileExists(atPath: home + "/.config/cloud-code")
        {
            recognized.insert("cloudcode")
        }
        if fs.fileExists(atPath: home + "/.gemini") { recognized.insert("antigravity") }
        if fs.fileExists(atPath: home + "/.codeium/windsurf") { recognized.insert("windsurf") }
        if fs.fileExists(atPath: home + "/.local/state/kilo") { recognized.insert("kilo") }
        if OpenRouterUsageAdapter.detect(home: home) { recognized.insert("openrouter") }
        if OllamaUsageAdapter.detect(home: home) { recognized.insert("ollama") }
        if OpenCodeUsageAdapter.detect(home: home) { recognized.insert("opencode") }

        if recognized.isEmpty {
            recognized = ["claude", "codex", "cursor"]
        }

        // Build quota rows from provider-reported sources only. Anything
        // without a live quota (quota-axi, Claude rate limits, cached
        // OpenRouter/Ollama) is skipped: no budget-derived percentages, no
        // activity-derived request counts, and no rows for tools that merely
        // have a directory on disk.
        //
        // opencode is the measured exception: it has no quota API, but the
        // ledger records free-tier limit walls (QuotaExceeded) plus exact
        // daily spend. Its row reports that measured state, never a
        // fabricated percentage.
        for p in recognized.sorted() {
            switch p {
            case "claude":
                if let live = ClaudeUsageAdapter.quota(home: home) {
                    var quota = live
                    quota.burnRateTPM = burnRateTPM
                    quota.hoursRemaining = forecastHoursRemaining(
                        tokensPerMin: burnRateTPM,
                        remainingPercent: live.remainingPercent)
                    results.append(quota)
                }
            case "opencode":
                if let state = OpenCodeUsageAdapter.quotaState(now: Date(), home: home) {
                    let tier =
                        (state.model?.lowercased().contains("free") == true)
                        ? "Free tier" : (state.model ?? "Managed models")
                    results.append(
                        ProviderQuota(
                            provider: "opencode",
                            remainingPercent: 100,
                            resetHint: "Free tier · no quota",
                            tier: tier,
                            usedDisplay: String(
                                format: "$%.2f today · %d requests",
                                state.costTodayUSD, state.requestCount),
                            totalDisplay: "Measured",
                            burnRateTPM: burnRateTPM,
                            hidesProgress: true
                        ))
                }
                let bundled = OpenCodeUsageAdapter.goBundledSpend(
                    now: Date(), home: home)
                if bundled.spend5h + bundled.spend7d + bundled.spend30d > 0 {
                    if let row = Self.opencodeGoRow(
                        bundled: bundled,
                        home: home,
                        burnRateTPM: burnRateTPM,
                        monthlyAllowanceUSD: goMonthlyAllowanceUSD)
                    {
                        results.append(row)
                    }
                }
            case "openrouter":
                if let cached = OpenRouterUsageAdapter.cachedQuota {
                    var quota = cached
                    quota.burnRateTPM = burnRateTPM
                    quota.hoursRemaining = forecastHoursRemaining(
                        tokensPerMin: burnRateTPM,
                        remainingPercent: cached.remainingPercent)
                    results.append(quota)
                }
            case "ollama":
                if let cached = OllamaUsageAdapter.cachedQuota {
                    var quota = cached
                    quota.burnRateTPM = burnRateTPM
                    results.append(quota)
                }
            default:
                continue
            }
        }

        return results
    }

    /// One bundled opencode Go row, or nil when wall-clock spend cannot be
    /// metered against the monthly allowance. Pure apart from the clock.
    static func opencodeGoRow(
        bundled: OpenCodeUsageAdapter.GoBundledSpend,
        home: String,
        burnRateTPM: Double,
        monthlyAllowanceUSD: Double
    ) -> ProviderQuota? {
        let now = Date()
        let walls = OpenCodeUsageAdapter.goWallState(now: now, home: home)
        let wallsToday = walls?.wallsToday ?? 0
        let limitedNow = walls?.limitedNow ?? false
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let tight = OpenCodeUsageAdapter.tightestAllowanceWindow(
            usages: [
                OpenCodeUsageAdapter.GoWindowUsage(
                    label: "5-hour", lengthMs: 5 * 3_600 * 1_000,
                    fraction: 0.2, spend: bundled.spend5h,
                    oldestMs: bundled.oldest5hMs),
                OpenCodeUsageAdapter.GoWindowUsage(
                    label: "weekly", lengthMs: 7 * 86_400 * 1_000,
                    fraction: 0.5, spend: bundled.spend7d,
                    oldestMs: bundled.oldest7dMs),
                OpenCodeUsageAdapter.GoWindowUsage(
                    label: "monthly", lengthMs: 30 * 86_400 * 1_000,
                    fraction: 1.0, spend: bundled.spend30d,
                    oldestMs: bundled.oldest30dMs),
            ],
            monthlyAllowance: monthlyAllowanceUSD,
            nowMs: nowMs)
        let wallSuffix = wallsToday == 1 ? "" : "s"
        let wallsText = "\(wallsToday) limit wall\(wallSuffix) today"
        let resetHint = wallsToday > 0 ? wallsText : "Tightest \(tight.label) window"
        let remaining = limitedNow ? 0.0 : 100.0 - tight.percentUsed
        let used = String(
            format: "5h $%.2f · 7d $%.2f · 30d $%.2f",
            bundled.spend5h, bundled.spend7d, bundled.spend30d)
        let total = String(format: "$%.0f / mo allowance", monthlyAllowanceUSD)
        return ProviderQuota(
            provider: "opencode Go",
            remainingPercent: remaining,
            resetHint: resetHint,
            tier: "Go subscription",
            usedDisplay: used,
            totalDisplay: total,
            burnRateTPM: burnRateTPM,
            limitReached: limitedNow,
            isEstimated: true
        )
    }

    private static func cleanProviderName(_ raw: String) -> String {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("claude") || lower.contains("anthropic") { return "claude" }
        if lower.contains("codex") || lower.contains("openai") { return "codex" }
        if lower.contains("cursor") { return "cursor" }
        if lower.contains("cloudcode") || lower.contains("cloud-code") { return "cloudcode" }
        if lower.contains("antigravity") || lower.contains("agy") || lower.contains("gemini") {
            return "antigravity"
        }
        if lower.contains("windsurf") || lower.contains("cascade") { return "windsurf" }
        if lower.contains("kilo") { return "kilo" }
        if lower.contains("openrouter") { return "openrouter" }
        if lower.contains("ollama") { return "ollama" }
        return lower
    }

    /// Estimates hours remaining until quota limit based on current burn rate.
    public static func forecastHoursRemaining(tokensPerMin: Double, remainingPercent: Double)
        -> Double?
    {
        guard tokensPerMin > 50.0, remainingPercent > 0.0 else { return nil }
        // Assume nominal 500k token quota window
        let estimatedRemainingTokens = (remainingPercent / 100.0) * 500_000.0
        let minutesLeft = estimatedRemainingTokens / tokensPerMin
        return min(max(minutesLeft / 60.0, 0.1), 99.0)
    }

    /// Whether current burn rate triggers a high velocity quota alert.
    public static func isHighBurnRate(tokensPerMin: Double) -> Bool {
        tokensPerMin >= 2500.0
    }
}
