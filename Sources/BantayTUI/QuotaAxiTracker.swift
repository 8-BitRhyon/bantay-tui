import Foundation

/// Provider quota status representation from `quota-axi` or local usage engines.
public struct ProviderQuota: Identifiable, Codable, Equatable, Sendable {
    public var id: String { provider }
    public var provider: String
    public var remainingPercent: Double
    public var resetHint: String
    public var tier: String
    public var isWarning: Bool { remainingPercent <= 20.0 }

    public init(
        provider: String,
        remainingPercent: Double,
        resetHint: String = "24h",
        tier: String = "Pro"
    ) {
        self.provider = provider
        self.remainingPercent = min(max(remainingPercent, 0.0), 100.0)
        self.resetHint = resetHint
        self.tier = tier
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
                    tier: item.tier ?? "Standard"
                )
            }
        } catch {
            return []
        }
    }

    /// Provides fallback / synthetic quotas for detected active providers when quota-axi CLI is not installed.
    public static func fallbackQuotas(activeProviders: [String], costUSD: Double, budgetUSD: Double)
        -> [ProviderQuota]
    {
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
}
