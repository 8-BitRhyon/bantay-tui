import AppKit
import SwiftUI

/// Split status strip dividing active agents and alerts into left and right wings beside the physical notch cutout.
struct CenteredSplitStripView: View {
    @ObservedObject var eventManager = AgentEventManager.shared
    let islandWidth: CGFloat
    let islandHeight: CGFloat

    private var agents: [AgentSnapshot] {
        eventManager.agents
    }

    private var needsYou: [AgentSnapshot] {
        agents.filter { $0.kind == .accessRequest || $0.kind == .waiting }
    }

    private var working: [AgentSnapshot] {
        agents.filter { $0.kind.isOngoing && $0.kind != .accessRequest }
    }

    private var failed: [AgentSnapshot] {
        agents.filter { $0.kind == .failed }
    }

    private var sideWidth: CGFloat {
        let windowW = IslandMetrics.windowSize().width
        return max(
            (windowW
                - IslandMetrics.notchWidth(
                    screenWidth: AppDelegate.islandScreen()?.frame.width ?? windowW,
                    auxLeft: AppDelegate.auxLeftWidth,
                    auxRight: AppDelegate.auxRightWidth,
                    safeTop: AppDelegate.topInset)) / 2, 0)
    }

    var body: some View {
        let notchPad: CGFloat = 8
        HStack(spacing: 0) {
            leftWingView
                .padding(.trailing, notchPad)
                .frame(width: sideWidth, alignment: .trailing)

            Spacer(minLength: 0)

            rightWingView
                .padding(.leading, notchPad)
                .frame(width: sideWidth, alignment: .leading)
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .top)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leftWingView: some View {
        let left = working.prefix(3)
        HStack(spacing: IslandMetrics.idleChipGap) {
            if !left.isEmpty {
                ForEach(Array(left.enumerated()), id: \.element.id) { _, agent in
                    HStack(spacing: IslandMetrics.idleChipDotGap) {
                        Circle()
                            .fill(Color(hex: agent.kind.color))
                            .frame(
                                width: IslandMetrics.idleDotSize,
                                height: IslandMetrics.idleDotSize)
                        Text(agent.source)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, IslandMetrics.idleChipHPad)
                    .frame(height: 20)
                    .background(Color.white.opacity(0.10), in: Capsule())
                }
                if working.count > left.count {
                    Text("+\(working.count - left.count)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                }
            } else if let event = eventManager.currentEvent, event.kind.isOngoing {
                HStack(spacing: IslandMetrics.idleChipDotGap) {
                    Circle()
                        .fill(Color(hex: event.kind.color))
                        .frame(
                            width: IslandMetrics.idleDotSize,
                            height: IslandMetrics.idleDotSize)
                    Text(
                        event.title.map { IslandMetrics.cleanHUDText($0, maxCharacters: 40) }
                            .flatMap { $0.isEmpty ? nil : $0 } ?? event.kind.label
                    )
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                }
                .padding(.horizontal, IslandMetrics.idleChipHPad)
                .frame(height: 20)
                .background(Color.white.opacity(0.10), in: Capsule())
            } else {
                HStack(spacing: IslandMetrics.idleChipDotGap) {
                    Circle()
                        .fill(Color(hex: "34D399"))
                        .frame(
                            width: IslandMetrics.idleDotSize,
                            height: IslandMetrics.idleDotSize)
                    Text("Bantay")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.horizontal, IslandMetrics.idleChipHPad)
                .frame(height: 20)
                .background(Color.white.opacity(0.10), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var rightWingView: some View {
        HStack(spacing: 5) {
            if !needsYou.isEmpty {
                Circle().fill(Color(hex: AgentEventKind.accessRequest.color))
                    .frame(width: 7, height: 7)
                Text("\(needsYou.count) need you")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
            if !failed.isEmpty {
                Circle().fill(Color(hex: AgentEventKind.failed.color))
                    .frame(width: 7, height: 7)
                Text("\(failed.count) failed")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
            if needsYou.isEmpty && failed.isEmpty {
                Text("Idle")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, IslandMetrics.idleChipHPad)
        .frame(height: 20)
        .background(Color.white.opacity(0.08), in: Capsule())
    }
}

/// Compact closed pill for transient event display.
struct ClosedPillView: View {
    let color: String
    let label: String
    let title: String?
    var dots: [AgentEventKind] = []
    let mascotState: MascotState
    let islandWidth: CGFloat
    let islandHeight: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if NotchHUDConfig.shared.showNotchMascot {
                    MascotView(
                        archetype: NotchHUDConfig.shared.selectedMascotArchetype,
                        state: mascotState,
                        size: 13
                    )
                } else {
                    Circle().fill(Color(hex: color)).frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                if let title {
                    Text("·").foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !dots.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(dots.prefix(5).enumerated()), id: \.offset) { _, kind in
                            Circle().fill(Color(hex: kind.color)).frame(width: 4, height: 4)
                        }
                        if dots.count > 5 {
                            Text("+\(dots.count - 5)")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                }
            }
            .frame(width: islandWidth, height: islandHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Idle strip displaying chips or dots for active agents according to user preference.
struct AgentIdleStripView: View {
    @ObservedObject var eventManager = AgentEventManager.shared
    let islandWidth: CGFloat
    let islandHeight: CGFloat
    let idleShownCount: Int

    var body: some View {
        let agents = eventManager.agents
        let shown = idleShownCount
        let overflow = max(agents.count - shown, 0)
        ZStack {
            switch NotchHUDConfig.shared.idleStyle {
            case .dots:
                dotsStrip(agents: agents, shown: shown, overflow: overflow)
            case .summary:
                summaryStrip(count: agents.count)
            case .names:
                namesStrip(agents: agents, shown: shown, overflow: overflow)
            }
        }
        .frame(width: islandWidth, height: islandHeight)
        .clipped()
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            recentCompletionBadge
        }
    }

    private func dotsStrip(agents: [AgentSnapshot], shown: Int, overflow: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(agents.prefix(shown).enumerated()), id: \.offset) { _, agent in
                Circle()
                    .fill(Color(hex: agent.kind.color))
                    .frame(
                        width: IslandMetrics.idleDotSize, height: IslandMetrics.idleDotSize)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, IslandMetrics.idleChipHPad)
    }

    private func summaryStrip(count: Int) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: AgentEventKind.idle.color))
                .frame(width: 7, height: 7)
            Text("\(count) agent\(count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
    }

    private func namesStrip(agents: [AgentSnapshot], shown: Int, overflow: Int) -> some View {
        HStack(spacing: IslandMetrics.idleChipGap) {
            ForEach(Array(agents.prefix(shown).enumerated()), id: \.offset) { _, agent in
                HStack(spacing: IslandMetrics.idleChipDotGap) {
                    Circle()
                        .fill(Color(hex: agent.kind.color))
                        .frame(
                            width: IslandMetrics.idleDotSize,
                            height: IslandMetrics.idleDotSize)
                    Text(agent.source)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, IslandMetrics.idleChipHPad)
                .frame(height: 20)
                .background(Color.white.opacity(0.10), in: Capsule())
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    @ViewBuilder
    private var recentCompletionBadge: some View {
        if !eventManager.recentCompletions.isEmpty {
            Text("\(eventManager.recentCompletions.count) recent")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Color.teal.opacity(0.85), in: Capsule())
                .offset(x: -5, y: -4)
                .accessibilityLabel(
                    "\(eventManager.recentCompletions.count) recent agent completions")
        }
    }
}
