import SwiftUI

/// Roster view of active, working, and idle agents with grouping and empty states.
struct NotchRosterView: View {
    let visibleAgents: [AgentSnapshot]
    let mergedRoster: [AgentSnapshot]
    let recentCompletions: [RecentCompletion]
    let rosterScrollHeight: CGFloat
    let focusedRow: Int?

    let adapter: PlexerAdapter
    @Binding var hoveredRow: String?
    @Binding var composingPaneId: String?
    @Binding var promptText: String
    @FocusState.Binding var promptFocused: Bool
    @Binding var queueSelections: [String: Set<Int>]
    let reduceMotion: Bool
    let now: Date
    let onFocus: (AgentSnapshot) -> Void
    let onSubmitPrompt: () -> Void
    let onCancelComposing: () -> Void
    let onBeginComposing: (AgentSnapshot) -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                if visibleAgents.isEmpty {
                    emptyStateView
                } else if NotchHUDConfig.shared.expandedGroupByState {
                    groupedAgentRows
                } else {
                    flatAgentRows
                }
            }
        }
        .frame(height: rosterScrollHeight)
        .scrollIndicators(.hidden)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.25))
            Text("No agents detected")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            Text("Start Claude Code, Codex, or opencode\nand they'll appear here.")
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(.white.opacity(0.3))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: rosterScrollHeight)
    }

    private var groupedAgentRows: some View {
        let grouped = Dictionary(grouping: mergedRoster) { agent in
            IslandMetrics.expandedGroupRank(agent.kind)
        }
        return VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { rank in
                let rows = grouped[rank] ?? []
                if !rows.isEmpty {
                    sectionHeader(
                        IslandMetrics.groupLabel(rank: rank), count: rows.count,
                        color: rows.first?.kind.color ?? "#8a8aa8")
                    ForEach(rows) { agent in
                        agentRow(agent: agent)
                    }
                }
            }
            recentActivitySection
        }
    }

    private var flatAgentRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(mergedRoster.enumerated()), id: \.element.id) { index, agent in
                VStack(spacing: 0) {
                    if index > 0 {
                        Rectangle().fill(.white.opacity(0.04)).frame(height: 1)
                    }
                    agentRow(agent: agent)
                        .background(
                            focusedRow == index
                                ? Color.accentColor.opacity(0.18) : Color.clear
                        )
                }
                .transition(.opacity)
            }
            recentActivitySection
        }
    }

    @ViewBuilder
    private var recentActivitySection: some View {
        if !recentCompletions.isEmpty {
            sectionHeader("Recent", count: recentCompletions.count, color: "#8a8aa8")
            ForEach(recentCompletions) { recent in
                recentCompletionRow(recent)
            }
        }
    }

    private func recentCompletionRow(_ recent: RecentCompletion) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(
                    recent.kind == .failed
                        ? Color(hex: AgentEventKind.failed.color)
                        : Color(hex: AgentEventKind.completed.color)
                )
                .frame(width: 6, height: 6)
            Text(recent.source)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            if let title = recent.title {
                let clean = IslandMetrics.cleanHUDText(title)
                if !clean.isEmpty {
                    Text(clean)
                        .font(.system(size: 8.5, weight: .regular))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if let duration = recent.duration {
                Text(
                    IslandMetrics.elapsedLabel(
                        since: Date(timeIntervalSinceNow: -duration), now: Date())
                )
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.3))
            }
            Text(IslandMetrics.elapsedLabel(since: recent.createdAt, now: now))
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .frame(height: IslandMetrics.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(recent.source) \(recent.kind == .failed ? "failed" : "completed")"
                + (recent.title.flatMap {
                    let c = IslandMetrics.cleanHUDText($0)
                    return c.isEmpty ? nil : ": \(c)"
                } ?? ""))
    }

    private func sectionHeader(_ title: String, count: Int, color: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: color)).frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: IslandMetrics.sectionHeaderHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) agents")
    }

    private func agentRow(agent: AgentSnapshot) -> some View {
        AgentRowView(
            agent: agent,
            adapter: adapter,
            hoveredRow: $hoveredRow,
            composingPaneId: $composingPaneId,
            promptText: $promptText,
            promptFocused: $promptFocused,
            queueSelections: $queueSelections,
            reduceMotion: reduceMotion,
            now: now,
            onFocus: onFocus,
            onSubmitPrompt: onSubmitPrompt,
            onCancelComposing: onCancelComposing,
            onBeginComposing: onBeginComposing
        )
    }
}

/// Attention triage view: only agents that need input or failed.
struct NotchAttentionView: View {
    let mergedRoster: [AgentSnapshot]
    let adapter: PlexerAdapter
    @Binding var hoveredRow: String?
    @Binding var composingPaneId: String?
    @Binding var promptText: String
    @FocusState.Binding var promptFocused: Bool
    @Binding var queueSelections: [String: Set<Int>]
    let reduceMotion: Bool
    let now: Date
    let onFocus: (AgentSnapshot) -> Void
    let onSubmitPrompt: () -> Void
    let onCancelComposing: () -> Void
    let onBeginComposing: (AgentSnapshot) -> Void

    var body: some View {
        let rows = IslandMetrics.attentionFilter(mergedRoster)
        return VStack(spacing: 0) {
            if rows.isEmpty {
                Text("Nothing needs you")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .frame(height: IslandMetrics.rowHeight)
            }
            ForEach(rows) { agent in
                AgentRowView(
                    agent: agent,
                    adapter: adapter,
                    hoveredRow: $hoveredRow,
                    composingPaneId: $composingPaneId,
                    promptText: $promptText,
                    promptFocused: $promptFocused,
                    queueSelections: $queueSelections,
                    reduceMotion: reduceMotion,
                    now: now,
                    onFocus: onFocus,
                    onSubmitPrompt: onSubmitPrompt,
                    onCancelComposing: onCancelComposing,
                    onBeginComposing: onBeginComposing
                )
            }
            Spacer(minLength: 0)
        }
    }
}
