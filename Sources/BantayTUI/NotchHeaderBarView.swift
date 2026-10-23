import SwiftUI

/// Header bar displayed at the top of the expanded Notch HUD panel.
struct NotchHeaderBarView: View {
    @ObservedObject var eventManager: AgentEventManager
    @ObservedObject private var quotaMonitor = QuotaMonitor.shared
    @ObservedObject private var desktopHUD = DesktopHUDController.shared
    let counts: IslandMetrics.AgentCounts
    let mascotState: MascotState
    @Binding var selectedTab: ShelfTab
    @Binding var historyMode: HistoryMode
    @Binding var showThoughtBubble: Bool
    let panelPinned: Bool
    let onTogglePin: () -> Void
    let onOpenSettings: () -> Void
    let onExpandTo: (Bool) -> Void

    private var hasUsageData: Bool {
        quotaMonitor.hasUsageData
    }

    var body: some View {
        HStack(spacing: BantayTheme.space8) {
            if NotchHUDConfig.shared.showNotchMascot {
                mascotButton
            }
            if counts.needsInput > 0 {
                Text("\(counts.needsInput) need you")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .monospacedDigit()
                    .foregroundColor(BantayTheme.statusAttention)
            }
            if counts.working > 0 {
                Text("\(counts.working) working")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .monospacedDigit()
                    .foregroundColor(BantayTheme.statusWorking)
            }
            if counts.needsInput == 0 && counts.working == 0 {
                Text("Agents")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(BantayTheme.textPrimary)
            }
            if NotchHUDConfig.shared.enableSpendGlow {
                spendGaugeBadge
            }
            let liveRate = eventManager.usageRate.tokensPerMinute ?? 0
            if NotchHUDConfig.shared.showTokenRate, liveRate > 0 {
                tokenRateBadge(tpm: Int(liveRate))
            }
            if NotchHUDConfig.shared.enableQuotaAxiGauge, quotaMonitor.hasLiveQuota,
                hasUsageData, quotaMonitor.minRemainingPercent < 100
            {
                quotaAxiBadge
            }
            Spacer(minLength: 4)
            if let rawTitle = eventManager.currentEvent?.title,
                !rawTitle.hasPrefix("Created At:"),
                !rawTitle.contains("timestamp="),
                !rawTitle.contains("level=")
            {
                let cleanedTitle = IslandMetrics.cleanHUDText(rawTitle)
                if !cleanedTitle.isEmpty {
                    activeEventBadge(title: cleanedTitle)
                }
            }
            pinButton
            desktopBridgePill
            settingsButton
        }
        .padding(.horizontal, 14)
        .frame(height: IslandMetrics.headerHeight)
    }

    /// Lightweight bridge to Desktop mode. Observes only the HUD
    /// controller (toggle/window-count changes), never the strip manager,
    /// so strip scrolling cannot re-render the notch header.
    private var desktopBridgePill: some View {
        Button {
            desktopHUD.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 8, weight: .semibold))
                Text("Desktop \(desktopHUD.windowCount)")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundColor(BantayTheme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.05), in: Capsule())
            .fixedSize(horizontal: true, vertical: true)
        }
        .buttonStyle(.plain)
        .help("Open the Desktop strip HUD")
        .accessibilityLabel("Open Desktop strip HUD, \(desktopHUD.windowCount) windows")
    }

    private var mascotButton: some View {
        Button {
            withAnimation(BantayTheme.springSnappy) {
                showThoughtBubble.toggle()
            }
        } label: {
            MascotView(
                archetype: NotchHUDConfig.shared.selectedMascotArchetype,
                state: mascotState,
                size: 16
            )
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showThoughtBubble, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(NotchHUDConfig.shared.selectedMascotArchetype.displayName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(BantayTheme.color(for: mascotState))
                    Spacer(minLength: 0)
                    Text("Lv.\(NotchHUDConfig.shared.mascotLevel)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(BantayTheme.textTertiary)
                }
                Text(
                    "“\(NotchHUDConfig.shared.selectedMascotArchetype.personalityQuote(for: mascotState))”"
                )
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(BantayTheme.textPrimary)
                .lineLimit(3)
            }
            .padding(10)
            .frame(width: 200)
            .background(BantayTheme.panelBackground)
            .overlay(
                RoundedRectangle(cornerRadius: BantayTheme.radiusMedium)
                    .stroke(
                        BantayTheme.color(for: mascotState).opacity(0.35),
                        lineWidth: 1)
            )
        }
        .help(
            "\(NotchHUDConfig.shared.selectedMascotArchetype.displayName): “\(NotchHUDConfig.shared.selectedMascotArchetype.personalityQuote(for: mascotState))”"
        )
        .accessibilityLabel(
            "\(NotchHUDConfig.shared.selectedMascotArchetype.displayName): \(mascotState.statusText)"
        )
    }

    private var spendGaugeBadge: some View {
        let cost = eventManager.usage.costUSD
        let budget = max(NotchHUDConfig.shared.dailyBudgetUSD, 0.5)
        let ratio = cost / budget
        let formattedCost = String(format: "$%.2f", cost)
        let formattedBudget =
            budget >= 10 && budget.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "$%.0f", budget)
            : String(format: "$%.2f", budget)
        let color: Color =
            ratio >= 1.0
            ? BantayTheme.statusFailed
            : (ratio >= 0.7 ? BantayTheme.statusQuota : BantayTheme.statusWorking)
        return HStack(spacing: BantayTheme.space4) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text("\(formattedCost)/\(formattedBudget)")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .monospacedDigit()
                .foregroundColor(color)
        }
        .padding(.horizontal, BantayTheme.space6)
        .padding(.vertical, BantayTheme.space2)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.28), lineWidth: 0.5))
        .fixedSize(horizontal: true, vertical: true)
        .help("Daily AI Spend: \(formattedCost) of \(formattedBudget) limit")
    }

    private func tokenRateBadge(tpm: Int) -> some View {
        let rateText: String = {
            if tpm >= 1000 {
                return String(format: "⚡%.1fk/m", Double(tpm) / 1000.0)
            } else {
                return "⚡\(tpm)/m"
            }
        }()
        let color = BantayTheme.statusWorking
        return HStack(spacing: BantayTheme.space2) {
            Text(rateText)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .monospacedDigit()
                .foregroundColor(color)
        }
        .padding(.horizontal, BantayTheme.space6)
        .padding(.vertical, BantayTheme.space2)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.28), lineWidth: 0.5))
        .fixedSize(horizontal: true, vertical: true)
        .help("Live token processing rate over the last minute")
        .accessibilityLabel("Token rate \(tpm) tokens per minute")
    }

    private var quotaAxiBadge: some View {
        let percentInt = quotaMonitor.minRemainingPercent
        let color: Color =
            percentInt <= 20
            ? BantayTheme.statusFailed
            : (percentInt <= 50 ? BantayTheme.statusQuota : BantayTheme.statusCompleted)

        return Button {
            onExpandTo(true)
            selectedTab = .history
            historyMode = .quotas
        } label: {
            HStack(spacing: BantayTheme.space4) {
                Circle().fill(color).frame(width: 4, height: 4)
                Text("Q:\(percentInt)%")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .monospacedDigit()
                    .foregroundColor(color)
            }
            .padding(.horizontal, BantayTheme.space6)
            .padding(.vertical, BantayTheme.space2)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.28), lineWidth: 0.5))
            .fixedSize(horizontal: true, vertical: true)
        }
        .buttonStyle(.plain)
        .help("Live Provider Quotas: Click to view details (\(percentInt)% remaining)")
        .accessibilityLabel("Quota remaining \(percentInt) percent")
    }

    private func activeEventBadge(title: String) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(BantayTheme.statusWorking)
                .frame(width: 4, height: 4)
            Text(title)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundColor(BantayTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.06), in: Capsule())
        .frame(maxWidth: 130, alignment: .trailing)
        .help("Active Event: \(title)")
    }

    private var pinButton: some View {
        Button(action: onTogglePin) {
            Image(systemName: panelPinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    panelPinned ? BantayTheme.statusWorking : BantayTheme.textTertiary
                )
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(panelPinned ? "Unpin panel" : "Pin panel open")
        .accessibilityLabel(panelPinned ? "Unpin panel" : "Pin panel open")
        .accessibilityValue(panelPinned ? "pinned" : "unpinned")
    }

    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BantayTheme.textTertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Settings")
        .accessibilityLabel("Open Settings")
    }
}
