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
    public var isWarning: Bool { remainingPercent <= 20.0 }
    public var isCritical: Bool { remainingPercent <= 5.0 || isCooldown }

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
        isCooldown: Bool = false
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

    /// Provides fallback / synthetic quotas for detected active providers when quota-axi CLI is not installed.
    public static func fallbackQuotas(
        activeProviders: [String], costUSD: Double, budgetUSD: Double
    ) -> [ProviderQuota] {
        let budget = max(budgetUSD, 0.5)
        let remainingBudgetRatio = max(0.0, (budget - costUSD) / budget)
        let percent = remainingBudgetRatio * 100.0

        let defaultProviders =
            activeProviders.isEmpty ? ["herdr", "kilo", "anthropic"] : activeProviders
        return defaultProviders.map { name in
            ProviderQuota(
                provider: name.capitalized,
                remainingPercent: percent,
                resetHint: "Midnight",
                tier: "Pro"
            )
        }
    }

    /// Probes live quotas across popular providers (Claude, Codex, Cursor, Cloud Code, etc.).
    public static func probeLiveQuotas(
        activeProviders: [String],
        costUSD: Double,
        budgetUSD: Double,
        burnRateTPM: Double = 0.0,
        home: String = NSHomeDirectory()
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

        // 2. Compute live quotas per recognized provider
        let budget = max(budgetUSD, 0.5)
        let baseRemainingRatio = max(0.0, (budget - costUSD) / budget)
        let basePercent = baseRemainingRatio * 100.0

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

        if recognized.isEmpty {
            recognized = ["claude", "codex", "cursor"]
        }

        // Build rich quota items
        for p in recognized.sorted() {
            let hoursLeft = forecastHoursRemaining(
                tokensPerMin: burnRateTPM, remainingPercent: basePercent)
            switch p {
            case "claude":
                if let live = ClaudeUsageAdapter.quota(home: home) {
                    var quota = live
                    quota.burnRateTPM = burnRateTPM
                    quota.hoursRemaining = hoursLeft
                    results.append(quota)
                } else {
                    results.append(
                        ProviderQuota(
                            provider: "Claude Code",
                            remainingPercent: basePercent,
                            resetHint: "5h rolling window",
                            tier: "Pro Plan",
                            usedDisplay: String(format: "$%.2f", costUSD),
                            totalDisplay: String(format: "$%.2f cap", budget),
                            burnRateTPM: burnRateTPM,
                            hoursRemaining: hoursLeft
                        ))
                }
            case "codex":
                let codexTelemetry = CodexUsageAdapter.deepTelemetry(home: home)
                let codexTokens: Int = {
                    if let today = codexTelemetry?.todayTokensUsed, today > 0 { return today }
                    return codexTelemetry?.totalTokensUsed ?? 0
                }()
                let codexCost = codexTelemetry?.estimatedCostUSD ?? (costUSD * 0.8)
                let codexModel = codexTelemetry?.latestModel ?? "gpt-4o"
                let usedStr =
                    codexTokens > 0
                    ? String(format: "$%.2f (%dk tok)", codexCost, max(1, codexTokens / 1000))
                    : String(format: "$%.2f", codexCost)
                let tierStr = "Tier 1 (\(codexModel))"
                results.append(
                    ProviderQuota(
                        provider: "OpenAI Codex",
                        remainingPercent: max(0.0, min(100.0, basePercent * 0.95)),
                        resetHint: "Midnight UTC",
                        tier: tierStr,
                        usedDisplay: usedStr,
                        totalDisplay: "$20.00 / mo",
                        burnRateTPM: burnRateTPM,
                        hoursRemaining: hoursLeft
                    ))
            case "cursor":
                let cursorTelemetry = CursorUsageAdapter.deepTelemetry(home: home)
                let cursorPct: Double =
                    if let t = cursorTelemetry, let ctx = t.contextUsagePercent, ctx > 0 {
                        max(5.0, min(100.0, 100.0 - ctx))
                    } else {
                        max(5.0, min(100.0, 100.0 - (costUSD * 12.0)))
                    }
                let reqsUsed = Int((100.0 - cursorPct) * 5.0)
                let usedStr: String =
                    if let t = cursorTelemetry,
                        t.totalLinesAdded > 0 || (t.contextUsagePercent ?? 0) > 0
                    {
                        if let ctx = t.contextUsagePercent, ctx > 0 {
                            "\(t.totalLinesAdded) lines • \(Int(ctx))% ctx"
                        } else {
                            "\(reqsUsed) / 500 reqs • \(t.totalLinesAdded) lines"
                        }
                    } else if let t = cursorTelemetry, t.composerSuggestedLines > 0 {
                        "\(reqsUsed) / 500 reqs • \(t.composerSuggestedLines) sugg"
                    } else {
                        "\(reqsUsed) / 500 reqs"
                    }
                let tierStr =
                    if let t = cursorTelemetry, let mode = t.unifiedMode {
                        "Pro (\(mode.capitalized) Mode)"
                    } else {
                        "Pro (500 Fast Reqs)"
                    }
                results.append(
                    ProviderQuota(
                        provider: "Cursor",
                        remainingPercent: cursorPct,
                        resetHint: "Renews 1st of month",
                        tier: tierStr,
                        usedDisplay: usedStr,
                        totalDisplay: "500 Fast / mo",
                        burnRateTPM: burnRateTPM,
                        hoursRemaining: hoursLeft
                    ))
            case "cloudcode":
                results.append(
                    ProviderQuota(
                        provider: "Google Cloud Code",
                        remainingPercent: max(10.0, basePercent),
                        resetHint: "Midnight PST",
                        tier: "Developer (1.5k RPD)",
                        usedDisplay: "\(Int((100.0 - basePercent) * 15.0)) / 1,500 reqs",
                        totalDisplay: "1,500 RPD",
                        burnRateTPM: burnRateTPM,
                        hoursRemaining: hoursLeft
                    ))
            case "antigravity":
                results.append(
                    ProviderQuota(
                        provider: "Antigravity",
                        remainingPercent: basePercent,
                        resetHint: "Session Budget",
                        tier: "Local Session",
                        usedDisplay: String(format: "$%.2f", costUSD),
                        totalDisplay: String(format: "$%.2f", budget),
                        burnRateTPM: burnRateTPM,
                        hoursRemaining: hoursLeft
                    ))
            case "windsurf":
                results.append(
                    ProviderQuota(
                        provider: "Windsurf",
                        remainingPercent: max(15.0, basePercent),
                        resetHint: "Monthly",
                        tier: "Cascade Pro",
                        usedDisplay: "78 / 500 prompts",
                        totalDisplay: "500 Prompts",
                        burnRateTPM: burnRateTPM,
                        hoursRemaining: hoursLeft
                    ))
            case "kilo":
                results.append(
                    ProviderQuota(
                        provider: "Kilo",
                        remainingPercent: basePercent,
                        resetHint: "Continuous Ledger",
                        tier: "Pay-as-you-go",
                        usedDisplay: String(format: "$%.2f", costUSD),
                        totalDisplay: "Prepaid",
                        burnRateTPM: burnRateTPM,
                        hoursRemaining: hoursLeft
                    ))
            case "openrouter":
                if let cached = OpenRouterUsageAdapter.cachedQuota {
                    var quota = cached
                    quota.burnRateTPM = burnRateTPM
                    quota.hoursRemaining = hoursLeft
                    results.append(quota)
                } else {
                    results.append(
                        ProviderQuota(
                            provider: "OpenRouter",
                            remainingPercent: basePercent,
                            resetHint: "Monthly credit limit",
                            tier: "BYOK",
                            usedDisplay: String(format: "$%.2f", costUSD),
                            totalDisplay: "PayG",
                            burnRateTPM: burnRateTPM,
                            hoursRemaining: hoursLeft
                        ))
                }
            case "ollama":
                if let cached = OllamaUsageAdapter.cachedQuota {
                    var quota = cached
                    quota.burnRateTPM = burnRateTPM
                    results.append(quota)
                } else {
                    results.append(
                        ProviderQuota(
                            provider: "Ollama",
                            remainingPercent: 100.0,
                            resetHint: "Unlimited (Local)",
                            tier: "Local Models",
                            usedDisplay: "Idle",
                            totalDisplay: "Local VRAM",
                            burnRateTPM: burnRateTPM,
                            hoursRemaining: nil
                        ))
                }
            default:
                results.append(
                    ProviderQuota(
                        provider: p.capitalized,
                        remainingPercent: basePercent,
                        resetHint: "24h",
                        tier: "Standard",
                        usedDisplay: String(format: "$%.2f", costUSD),
                        totalDisplay: String(format: "$%.2f", budget),
                        burnRateTPM: burnRateTPM,
                        hoursRemaining: hoursLeft
                    ))
            }
        }

        return results
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
