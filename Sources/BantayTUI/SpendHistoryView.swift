import AppKit
import SwiftUI

/// Micro-dashboard displaying daily/weekly token spend history, budget progress, and projected run-rate.
struct SpendHistoryView: View {
    @ObservedObject private var store = SpendHistoryStore.shared
    private let budget: Double

    init(budget: Double = NotchHUDConfig.shared.dailyBudgetUSD) {
        self.budget = budget
    }

    var body: some View {
        VStack(spacing: 8) {
            headerSummary
            weekBarChart
            agentBreakdown
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: BantayTheme.radiusCard, style: .continuous)
                .fill(BantayTheme.cardBackground)
        )
    }

    private var headerSummary: some View {
        let (projected, _) = store.projectedRunRate(budget: budget)
        let weekTotal = store.totalPastWeekUSD()

        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Past 7 Days")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(BantayTheme.textTertiary)
                Text(String(format: "$%.2f", weekTotal))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(BantayTheme.textPrimary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Projected Today")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(BantayTheme.textTertiary)
                Text(String(format: "$%.2f / day", projected))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(
                        projected > budget
                            ? BantayTheme.statusFailed
                            : (projected > budget * 0.8
                                ? BantayTheme.statusAttention : BantayTheme.statusWorking)
                    )
            }
        }
    }

    private var weekBarChart: some View {
        let days = store.recentDays(count: 7)
        let maxCost = max(days.map(\.totalCostUSD).max() ?? 0.0, budget * 0.5, 0.01)

        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(days) { day in
                let heightFraction = maxCost > 0 ? min(day.totalCostUSD / maxCost, 1.0) : 0
                let barHeight = max(CGFloat(heightFraction) * 32.0, 3.0)
                let dayLabel = String(day.dateKey.suffix(2))

                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            day.totalCostUSD >= budget
                                ? BantayTheme.statusFailed
                                : (day.totalCostUSD >= budget * 0.8
                                    ? BantayTheme.statusAttention : BantayTheme.statusWorking)
                        )
                        .frame(height: barHeight)

                    Text(dayLabel)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(BantayTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 48)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var agentBreakdown: some View {
        let todayKey = SpendHistoryStore.dateKey()
        let record = store.dailyRecords[todayKey]
        let byAgent = record?.costByAgent ?? [:]

        if !byAgent.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Today by Agent")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(BantayTheme.textTertiary)

                ForEach(byAgent.sorted(by: { $0.value > $1.value }), id: \.key) { agent, cost in
                    HStack {
                        Text(agent)
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundColor(BantayTheme.textSecondary)
                        Spacer()
                        Text(String(format: "$%.2f", cost))
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundColor(BantayTheme.statusCompleted)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}
