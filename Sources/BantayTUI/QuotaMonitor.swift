import Combine
import Foundation

/// Cached provider-quota state. The notch header previously probed
/// `quota-axi` synchronously inside `View.body`; every one-second UI tick
/// could therefore block the main thread on a subprocess plus disk scans.
/// This monitor refreshes on a background task and publishes cheap values.
@MainActor
final class QuotaMonitor: ObservableObject {
    static let shared = QuotaMonitor()
    nonisolated static let refreshInterval: TimeInterval = 60

    @Published private(set) var quotas: [ProviderQuota] = []
    @Published private(set) var minRemainingPercent: Int = 100
    @Published private(set) var hasUsageData: Bool = false
    @Published private(set) var hasLiveQuota: Bool = false
    @Published private(set) var lastRefresh: Date?

    private var pollTask: Task<Void, Never>?

    init() {}

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(force: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh(
        activeProviders: [String]? = nil,
        costUSD: Double? = nil,
        budgetUSD: Double? = nil,
        burnRateTPM: Double? = nil,
        force: Bool = false,
        now: Date = Date()
    ) async {
        if !force, !Self.shouldRefresh(lastRefresh: lastRefresh, now: now) {
            return
        }
        let manager = AgentEventManager.shared
        let providers = activeProviders ?? manager.agents.map(\.source)
        let cost = costUSD ?? manager.usage.costUSD
        let budget = budgetUSD ?? NotchHUDConfig.shared.dailyBudgetUSD
        let rate = burnRateTPM ?? (manager.usageRate.tokensPerMinute ?? 0.0)
        let allowance = NotchHUDConfig.shared.openCodeGoAllowanceUSD

        let probed = await Task.detached(priority: .utility) {
            QuotaAxiTracker.probeLiveQuotas(
                activeProviders: providers,
                costUSD: cost,
                budgetUSD: budget,
                burnRateTPM: rate,
                goMonthlyAllowanceUSD: allowance)
        }.value
        let kiloDetected = await Task.detached(priority: .utility) {
            KiloUsageAdapter.detect()
        }.value

        quotas = probed
        hasLiveQuota = !probed.isEmpty
        minRemainingPercent = Self.minRemainingPercent(quotas: probed)
        hasUsageData = Self.hasUsageData(
            kiloDetected: kiloDetected,
            totalTokens: manager.usage.totalTokens,
            tokensPerMinute: rate)
        lastRefresh = now
    }

    static func shouldRefresh(
        lastRefresh: Date?,
        now: Date = Date(),
        interval: TimeInterval = refreshInterval
    ) -> Bool {
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= interval
    }

    static func minRemainingPercent(quotas: [ProviderQuota]) -> Int {
        guard let minQuota = quotas.min(by: { $0.remainingPercent < $1.remainingPercent })
        else { return 100 }
        return Int(minQuota.remainingPercent)
    }

    static func hasUsageData(
        kiloDetected: Bool, totalTokens: Int, tokensPerMinute: Double
    ) -> Bool {
        kiloDetected || totalTokens > 0 || tokensPerMinute > 0
    }
}
