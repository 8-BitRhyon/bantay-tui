import AppKit
import SwiftUI

/// Project labels ordered by the most recently started agent. Ties keep the
/// roster order so the lead chip never jitters between heartbeats.
private func projectStripModel(
    for agents: [AgentSnapshot]
) -> (labels: [String], lead: AgentSnapshot?) {
    let ordered = agents.enumerated().sorted { lhs, rhs in
        let left = lhs.element.startedAt ?? .distantPast
        let right = rhs.element.startedAt ?? .distantPast
        if left != right { return left > right }
        return lhs.offset < rhs.offset
    }.map(\.element)
    let labels = IslandMetrics.compactProjectLabels(
        projects: ordered.map { $0.projectContext?.project },
        sources: ordered.map(\.source),
        startedAt: ordered.map(\.startedAt))
    return (labels, ordered.first)
}

/// Split status strip dividing active agents and alerts into left and right wings beside the physical notch cutout.
struct CenteredSplitStripView: View {
    @ObservedObject var eventManager = AgentEventManager.shared
    @AppStorage("idleStyle") private var idleStyleRaw = IslandMetrics.IdleStyle.project.rawValue
    let islandWidth: CGFloat
    let islandHeight: CGFloat

    private var idleStyle: IslandMetrics.IdleStyle {
        IslandMetrics.IdleStyle(rawValue: idleStyleRaw) ?? .project
    }

    /// Clearance between the chip row and the physical notch cutout.
    private let notchSidePad: CGFloat = 8

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

    /// Chips that fit beside the notch, with overflow folded into `+N`.
    private var chipFit: IslandMetrics.IdleChipFit {
        IslandMetrics.idleChipFit(
            agentCount: working.count,
            maxChips: NotchHUDConfig.shared.clampedIdleMaxChips,
            nameLengths: working.map(\.source.count),
            availableWidth: max(sideWidth - notchSidePad, 0))
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
        HStack(spacing: 0) {
            leftWingView
                .padding(.trailing, notchSidePad)
                .frame(width: sideWidth, alignment: .trailing)

            Spacer(minLength: 0)

            rightWingView
                .padding(.leading, notchSidePad)
                .frame(width: sideWidth, alignment: .leading)
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .top)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leftWingView: some View {
        if working.isEmpty {
            fallbackWing
        } else {
            switch idleStyle {
            case .project:
                projectWing
            case .summary:
                EmptyView()
            case .names:
                namesWing
            case .dots:
                dotsWing
            }
        }
    }

    /// Lead project plus a count of the other distinct projects. The right wing
    /// still owns the agent total, so this chip answers "what am I running".
    private var projectWing: some View {
        let model = projectStripModel(for: working)
        let labels = model.labels
        let sourceFallback = working.first?.source ?? ""
        let lead = labels.first ?? (sourceFallback.isEmpty ? "Agents" : sourceFallback)
        let overflow = max(labels.count - 1, 0)
        let maxCharacters = overflow > 0 ? 12 : 16
        let color = model.lead?.kind.color ?? AgentEventKind.progress.color
        return HStack(spacing: IslandMetrics.idleChipDotGap) {
            Circle()
                .fill(Color(hex: color))
                .frame(width: IslandMetrics.idleDotSize, height: IslandMetrics.idleDotSize)
            Text(IslandMetrics.cleanHUDText(lead, maxCharacters: maxCharacters))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, IslandMetrics.idleChipHPad)
        .frame(height: 20)
        .background(Color.white.opacity(0.10), in: Capsule())
        .help(
            "\(lead) · \(working.count) working agent\(working.count == 1 ? "" : "s")"
                + (labels.count > 1 ? " · \(labels.count) projects" : "")
        )
    }

    /// Fit-aware agent name chips, with overflow folded into `+N`.
    private var namesWing: some View {
        let left = Array(working.prefix(chipFit.shown))
        return HStack(spacing: IslandMetrics.idleChipGap) {
            ForEach(left) { agent in
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
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, IslandMetrics.idleChipHPad)
                .frame(height: 20)
                .background(Color.white.opacity(0.10), in: Capsule())
            }
            if chipFit.overflow > 0 {
                Text("+\(chipFit.overflow)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    /// One dot per working agent, capped so the wing never crowds the notch.
    private var dotsWing: some View {
        let shown = min(working.count, 6)
        return HStack(spacing: 5) {
            ForEach(Array(working.prefix(shown).enumerated()), id: \.offset) { _, agent in
                Circle()
                    .fill(Color(hex: agent.kind.color))
                    .frame(width: IslandMetrics.idleDotSize, height: IslandMetrics.idleDotSize)
            }
            if working.count > shown {
                Text("+\(working.count - shown)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, IslandMetrics.idleChipHPad)
        .frame(height: 20)
        .background(Color.white.opacity(0.10), in: Capsule())
        .help("\(working.count) working agent\(working.count == 1 ? "" : "s")")
    }

    /// No live working agents: keep the ongoing event title, or the resting
    /// Bantay chip when the notch is configured to stay visible.
    @ViewBuilder
    private var fallbackWing: some View {
        if let event = eventManager.currentEvent, event.kind.isOngoing {
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

    /// Right wing owns attention and failure. The resting "Idle" capsule is
    /// suppressed so a quiet notch is actually quiet.
    @ViewBuilder
    private var rightWingView: some View {
        if needsYou.isEmpty && failed.isEmpty && working.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 5) {
                if !needsYou.isEmpty {
                    Circle().fill(Color(hex: AgentEventKind.accessRequest.color))
                        .frame(width: 7, height: 7)
                    Text(
                        needsYou.count == 1
                            ? "1 needs you" : "\(needsYou.count) need you"
                    )
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
                    Circle().fill(Color(hex: AgentEventKind.progress.color))
                        .frame(width: 7, height: 7)
                    Text(IslandMetrics.centeredWorkingLabel(working: working.count))
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, IslandMetrics.idleChipHPad)
            .frame(height: 20)
            .background(Color.white.opacity(0.08), in: Capsule())
        }
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
    @AppStorage("idleStyle") private var idleStyleRaw = IslandMetrics.IdleStyle.project.rawValue
    let islandWidth: CGFloat
    let islandHeight: CGFloat
    let idleShownCount: Int

    private var idleStyle: IslandMetrics.IdleStyle {
        IslandMetrics.IdleStyle(rawValue: idleStyleRaw) ?? .project
    }

    var body: some View {
        let agents = eventManager.agents
        let shown = idleShownCount
        let overflow = max(agents.count - shown, 0)
        ZStack {
            switch idleStyle {
            case .dots:
                dotsStrip(agents: agents, shown: shown, overflow: overflow)
            case .summary:
                summaryStrip(count: agents.count)
            case .names:
                namesStrip(agents: agents, shown: shown, overflow: overflow)
            case .project:
                projectStrip(agents: agents)
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

    private func projectStrip(agents: [AgentSnapshot]) -> some View {
        let model = projectStripModel(for: agents)
        let labels = model.labels
        let lead = labels.first ?? "Agents"
        let overflow = max(labels.count - 1, 0)
        let state = model.lead?.kind.color ?? AgentEventKind.idle.color
        return HStack(spacing: 5) {
            Circle()
                .fill(Color(hex: state))
                .frame(width: 7, height: 7)
            Text(IslandMetrics.cleanHUDText(lead, maxCharacters: 14))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
            Text("· \(agents.count)")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(.horizontal, IslandMetrics.idleChipHPad)
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
