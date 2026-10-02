import AppKit
import SwiftUI

/// Micro-dashboard displaying live multi-provider quota status, remaining percentages, and tier limits.
struct ProviderQuotaView: View {
    @ObservedObject private var eventManager = AgentEventManager.shared
    @State private var quotas: [ProviderQuota] = []
    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 8) {
            headerBar

            if quotas.isEmpty {
                emptyQuotasView
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(quotas) { quota in
                            providerQuotaRow(quota)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: BantayTheme.radiusCard, style: .continuous)
                .fill(BantayTheme.cardBackground)
        )
        .onAppear {
            refreshQuotas()
        }
    }

    private var headerBar: some View {
        HStack {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.needle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(BantayTheme.statusQuota)
                Text("Provider Quotas & Limits")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(BantayTheme.textPrimary)
            }

            Spacer()

            Button(action: refreshQuotas) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8.5, weight: .semibold))
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    Text("Refresh")
                        .font(.system(size: 8.5, weight: .medium))
                }
                .foregroundColor(BantayTheme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyQuotasView: some View {
        VStack(spacing: 4) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 16))
                .foregroundColor(BantayTheme.textTertiary)
            Text("Probing provider quotas...")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(BantayTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 70)
    }

    private func providerQuotaRow(_ quota: ProviderQuota) -> some View {
        let percentInt = Int(quota.remainingPercent)
        let statusColor =
            quota.isCritical
            ? BantayTheme.statusFailed
            : (quota.isWarning ? BantayTheme.statusQuota : BantayTheme.statusCompleted)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 5) {
                    providerIcon(for: quota.provider)
                        .foregroundColor(statusColor)

                    Text(quota.provider)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(BantayTheme.textPrimary)
                        .lineLimit(1)

                    Text(quota.tier)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(BantayTheme.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    if quota.isCooldown {
                        Text("COOLDOWN")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundColor(BantayTheme.statusFailed)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(BantayTheme.statusFailed.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    if !quota.usedDisplay.isEmpty {
                        Text(quota.usedDisplay)
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundColor(BantayTheme.textSecondary)
                    }

                    Text("\(percentInt)%")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(statusColor)
                }
            }

            // Quota progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 4)

                    let barWidth =
                        geo.size.width * CGFloat(quota.remainingPercent / 100.0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(statusColor)
                        .frame(
                            width: max(0, min(barWidth, geo.size.width)),
                            height: 4
                        )
                }
            }
            .frame(height: 4)

            // Reset and burn rate details
            HStack {
                HStack(spacing: 3) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 7.5))
                    Text(quota.dynamicResetDescription())
                        .font(.system(size: 8, weight: .medium))
                }
                .foregroundColor(
                    quota.resetsAt != nil ? BantayTheme.statusQuota : BantayTheme.textTertiary
                )

                Spacer()

                if let hrs = quota.hoursRemaining {
                    Text(String(format: "~%.1fh left at current rate", hrs))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(
                            hrs < 3.0 ? BantayTheme.statusQuota : BantayTheme.textTertiary)
                } else if !quota.totalDisplay.isEmpty {
                    Text(quota.totalDisplay)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(BantayTheme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private func providerIcon(for provider: String) -> some View {
        let p = provider.lowercased()
        if p.contains("claude") || p.contains("anthropic") {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .semibold))
        } else if p.contains("codex") || p.contains("openai") {
            Image(systemName: "terminal.fill")
                .font(.system(size: 9, weight: .semibold))
        } else if p.contains("cursor") {
            Image(systemName: "cursor.rays")
                .font(.system(size: 9, weight: .semibold))
        } else if p.contains("cloud") {
            Image(systemName: "cloud.fill")
                .font(.system(size: 9, weight: .semibold))
        } else if p.contains("antigravity") || p.contains("gemini") {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 9, weight: .semibold))
        } else if p.contains("windsurf") || p.contains("cascade") {
            Image(systemName: "wind")
                .font(.system(size: 9, weight: .semibold))
        } else if p.contains("openrouter") {
            Image(systemName: "network")
                .font(.system(size: 9, weight: .semibold))
        } else if p.contains("ollama") {
            Image(systemName: "server.rack")
                .font(.system(size: 9, weight: .semibold))
        } else {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 9, weight: .semibold))
        }
    }

    private func refreshQuotas() {
        withAnimation(.easeInOut(duration: 0.4)) { isRefreshing = true }
        let active = eventManager.agents.map(\.source)
        let cost = eventManager.usage.costUSD
        let budget = NotchHUDConfig.shared.dailyBudgetUSD
        let rate = eventManager.usageRate.tokensPerMinute ?? 0.0

        quotas = QuotaAxiTracker.probeLiveQuotas(
            activeProviders: active,
            costUSD: cost,
            budgetUSD: budget,
            burnRateTPM: rate
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation { isRefreshing = false }
        }
    }
}
