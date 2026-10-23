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

    @State private var expandedGroups: Set<String> = []

    /// Blocked agents in roster order; drives approval cards and queue steppers.
    private var attentionAgents: [AgentSnapshot] {
        mergedRoster.filter { $0.kind == .accessRequest || $0.kind == .waiting }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                if visibleAgents.isEmpty {
                    emptyStateView
                } else if NotchHUDConfig.shared.expandedGroupByState {
                    inboxGroups
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

    /// Inbox layout: approval cards first, then working groups with
    /// collapsible subagents, then compact idle rows, then recent activity.
    private var inboxGroups: some View {
        let groups = AgentPresentation.groupRoster(mergedRoster)
        let attention = groups.filter(\.needsAttention)
        let working = groups.filter {
            !$0.needsAttention
                && ($0.lead.isWorking || $0.lead.kind == .failed
                    || $0.subagents.contains(where: \.isWorking))
        }
        let workingIDs = Set(working.map(\.id))
        let idle = groups.filter { !$0.needsAttention && !workingIDs.contains($0.id) }
        return VStack(spacing: 0) {
            if !attention.isEmpty {
                sectionHeader(
                    "Needs you", count: attentionAgents.count,
                    color: AgentEventKind.accessRequest.color)
                ForEach(attentionAgents) { agent in
                    approvalCard(
                        agent: agent,
                        index: attentionAgents.firstIndex(of: agent) ?? 0)
                }
            }
            if !working.isEmpty {
                sectionHeader(
                    "Working", count: working.reduce(0) { $0 + 1 + $1.subagents.count },
                    color: AgentEventKind.progress.color)
                ForEach(working) { group in
                    workingGroupRow(group)
                }
            }
            if !idle.isEmpty {
                sectionHeader(
                    "Idle", count: idle.reduce(0) { $0 + 1 + $1.subagents.count },
                    color: AgentEventKind.idle.color)
                ForEach(idle) { group in
                    agentRow(agent: group.lead)
                    ForEach(group.subagents) { sub in
                        agentRow(agent: sub)
                    }
                }
            }
            recentActivitySection
        }
    }

    private func workingGroupRow(_ group: AgentRosterGroup) -> some View {
        VStack(spacing: 0) {
            agentRow(agent: group.lead)
            if !group.subagents.isEmpty {
                subagentToggle(group)
                if expandedGroups.contains(group.id) {
                    ForEach(group.subagents) { sub in
                        agentRow(agent: sub)
                            .padding(.leading, 18)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(width: 1)
                                    .padding(.leading, 22)
                            }
                    }
                }
            }
        }
    }

    private func subagentToggle(_ group: AgentRosterGroup) -> some View {
        let expanded = expandedGroups.contains(group.id)
        return Button {
            if expanded {
                expandedGroups.remove(group.id)
            } else {
                expandedGroups.insert(group.id)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                Text(
                    expanded
                        ? "Hide subagents"
                        : "+\(group.subagents.count) subagent\(group.subagents.count == 1 ? "" : "s")"
                )
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 34)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Collapse subagents" : "Expand subagents")
        .accessibilityLabel(
            expanded
                ? "Collapse \(group.subagents.count) subagents"
                : "Expand \(group.subagents.count) subagents")
    }

    private func approvalCard(agent: AgentSnapshot, index: Int) -> some View {
        ApprovalCardView(
            agent: agent,
            queueIndex: index,
            queueTotal: attentionAgents.count,
            queueSelections: $queueSelections,
            onReview: {
                PeekPanelController.shared.show(agent: agent, adapter: adapter)
            },
            onFocus: { onFocus(agent) }
        )
    }

    private var flatAgentRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(mergedRoster.enumerated()), id: \.element.id) { index, agent in
                VStack(spacing: 0) {
                    if index > 0 {
                        Rectangle().fill(.white.opacity(0.04)).frame(height: 1)
                    }
                    if agent.kind == .accessRequest || agent.kind == .waiting {
                        approvalCard(
                            agent: agent,
                            index: attentionAgents.firstIndex(of: agent) ?? 0)
                    } else {
                        agentRow(agent: agent)
                            .background(
                                focusedRow == index
                                    ? Color.accentColor.opacity(0.18) : Color.clear
                            )
                    }
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
                        .font(.system(size: 9.5, weight: .regular))
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
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.3))
            }
            Text(IslandMetrics.elapsedLabel(since: recent.createdAt, now: now))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
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
            reduceMotion: reduceMotion,
            now: now,
            onFocus: onFocus,
            onSubmitPrompt: onSubmitPrompt,
            onCancelComposing: onCancelComposing,
            onBeginComposing: onBeginComposing
        )
    }
}

/// Attention triage view: approval cards for blocked agents, compact rows
/// for failures. Anything that needs input is actionable inline.
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

    private var attentionAgents: [AgentSnapshot] {
        IslandMetrics.attentionFilter(mergedRoster)
    }

    private var blockedAgents: [AgentSnapshot] {
        attentionAgents.filter { $0.kind == .accessRequest || $0.kind == .waiting }
    }

    var body: some View {
        let rows = attentionAgents
        return VStack(spacing: 0) {
            if rows.isEmpty {
                Text("Nothing needs you")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .frame(height: IslandMetrics.rowHeight)
            }
            ForEach(rows) { agent in
                if agent.kind == .accessRequest || agent.kind == .waiting {
                    ApprovalCardView(
                        agent: agent,
                        queueIndex: blockedAgents.firstIndex(of: agent) ?? 0,
                        queueTotal: blockedAgents.count,
                        queueSelections: $queueSelections,
                        onReview: {
                            PeekPanelController.shared.show(agent: agent, adapter: adapter)
                        },
                        onFocus: { onFocus(agent) }
                    )
                } else {
                    AgentRowView(
                        agent: agent,
                        adapter: adapter,
                        hoveredRow: $hoveredRow,
                        composingPaneId: $composingPaneId,
                        promptText: $promptText,
                        promptFocused: $promptFocused,
                        reduceMotion: reduceMotion,
                        now: now,
                        onFocus: onFocus,
                        onSubmitPrompt: onSubmitPrompt,
                        onCancelComposing: onCancelComposing,
                        onBeginComposing: onBeginComposing
                    )
                }
            }
            Spacer(minLength: 0)
        }
    }
}
