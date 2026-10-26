import AppKit
import SwiftUI

/// Micro-dashboard displaying daily/weekly token spend history, budget progress, and projected run-rate.
struct SpendHistoryView: View {
    @ObservedObject private var store = SpendHistoryStore.shared
    private let budget: Double

    private enum SpendScope: String, CaseIterable {
        case lifetime = "Lifetime"
        case week = "7 days"
        case day = "24 hours"
    }

    @State private var scope: SpendScope = .lifetime
    @State private var ledger: LedgerSnapshotData?

    init(budget: Double = NotchHUDConfig.shared.dailyBudgetUSD) {
        self.budget = budget
    }

    var body: some View {
        VStack(spacing: 8) {
            scopePills
            if let ledger {
                ledgerSection(snapshot: ledger)
            } else {
                // The SQLite scan behind the snapshot takes seconds on large
                // ledgers and runs off the main thread. Paint the skeleton
                // on the first frame so the tab switch never feels dead.
                LoadingSkeleton(rows: 2)
            }
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
        .onAppear {
            Task { await reloadLedger() }
        }
    }

    private func reloadLedger() async {
        ledger = await LedgerSnapshotCache.shared.snapshot()
    }

    private func ledgerScope() -> LedgerScope {
        switch scope {
        case .lifetime: return .lifetime
        case .week: return .week
        case .day: return .day
        }
    }

    private var scopePills: some View {
        HStack(spacing: 4) {
            Text("OPENCODE LEDGER")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(BantayTheme.textTertiary)
            Spacer(minLength: 0)
            ForEach(SpendScope.allCases, id: \.self) { option in
                Button {
                    scope = option
                } label: {
                    Text(option.rawValue)
                        .font(
                            .system(
                                size: 8.5,
                                weight: scope == option ? .bold : .medium)
                        )
                        .foregroundColor(
                            scope == option
                                ? BantayTheme.textPrimary : BantayTheme.textTertiary
                        )
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            scope == option
                                ? BantayTheme.cardSelected : Color.clear,
                            in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Spend window: \(option.rawValue)")
            }
        }
    }

    /// Authoritative ledger numbers for the selected window: lifetime
    /// totals plus streak, active days, and session count. The local
    /// sections below stay on device-local records; this row states its
    /// window so scopes never silently mix. Every scope derives from the
    /// one cached snapshot, so switching scopes is instant.
    private func ledgerSection(snapshot: LedgerSnapshotData) -> some View {
        let summary = ScopedLedger.summary(scope: ledgerScope(), snapshot: snapshot)
        return VStack(alignment: .leading, spacing: 4) {
            if scope == .lifetime, let sessions = summary.sessions {
                let tokens = summary.tokens
                let cost = summary.cost
                HStack(alignment: .firstTextBaseline) {
                    Text(IslandMetrics.compactTokenCount(tokens))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(BantayTheme.textPrimary)
                    Text("TOKENS LIFETIME")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(BantayTheme.textTertiary)
                    Spacer(minLength: 0)
                    Text(String(format: "$%.2f", cost))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(BantayTheme.statusCompleted)
                }
                HStack(spacing: 6) {
                    Text("\(sessions) sessions")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(BantayTheme.textSecondary)
                    Text("· \(summary.activeDays) active days")
                        .font(.system(size: 9))
                        .foregroundColor(BantayTheme.textTertiary)
                    Text("· \(summary.streakCurrent)-day streak")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(BantayTheme.statusAttention)
                    if summary.streakLongest > summary.streakCurrent {
                        Text("(best \(summary.streakLongest))")
                            .font(.system(size: 9))
                            .foregroundColor(BantayTheme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityLabel(
                    "\(tokens) lifetime tokens, $\(String(format: "%.2f", cost)), \(summary.streakCurrent) day streak"
                )
            } else {
                let tokens = summary.tokens
                let cost = summary.cost
                HStack(alignment: .firstTextBaseline) {
                    Text(IslandMetrics.compactTokenCount(tokens))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(BantayTheme.textPrimary)
                    Text("TOKENS · \(scope.rawValue.uppercased())")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(BantayTheme.textTertiary)
                    Spacer(minLength: 0)
                    Text(String(format: "$%.2f", cost))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(BantayTheme.statusCompleted)
                }
                .accessibilityLabel(
                    "\(tokens) tokens in the \(scope.rawValue), $\(String(format: "%.2f", cost))"
                )
            }
        }
    }

    private var headerSummary: some View {
        let (projected, _) = store.projectedRunRate(budget: budget)
        let weekTotal = store.totalPastWeekUSD()
        let todayTotal = store.dailyRecords[SpendHistoryStore.dateKey()]?.totalCostUSD ?? 0

        return VStack(alignment: .leading, spacing: 6) {
            Text("THIS MAC · LOCAL RECORDS")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(BantayTheme.textTertiary)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(BantayTheme.textTertiary)
                    Text(String(format: "$%.2f", todayTotal))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(BantayTheme.textPrimary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Past 7 Days")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(BantayTheme.textTertiary)
                    Text(String(format: "$%.2f", weekTotal))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(BantayTheme.textSecondary)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Projected Today")
                        .font(.system(size: 9.5, weight: .semibold))
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
            if todayTotal <= 0 {
                Text("No spend recorded today. Usage appears after an agent transcript changes.")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(BantayTheme.textTertiary)
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
