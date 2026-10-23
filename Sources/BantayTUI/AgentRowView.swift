import AppKit
import SwiftUI

/// Individual agent row within the expanded Notch HUD roster.
/// Extracted from NotchStatusView to decouple the monolithic view builder
/// and dramatically slash Swift compiler type-checking build times.
struct AgentRowView: View {
    let agent: AgentSnapshot
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

    private var agentKey: String {
        agent.paneId ?? "standalone:\(agent.source)"
    }

    private var isComposing: Bool {
        composingPaneId == agentKey
    }

    private var isRowHovered: Bool {
        hoveredRow == agent.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Pulsing status dot for working agents.
                Circle()
                    .fill(Color(hex: agent.kind.color))
                    .frame(width: 6, height: 6)
                    .modifier(
                        PulsingDotModifier(
                            enabled: (agent.kind == .progress || agent.kind == .started)
                                && !reduceMotion
                        )
                    )

                if isComposing {
                    composingFieldView
                } else {
                    agentDetailsAndActionsView
                }
            }
            .padding(.horizontal, 16)
            .frame(height: IslandMetrics.rowHeight)
        }
        .background(isRowHovered ? Color.white.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .modifier(AgentRowAccessibility(agent: agent))
        .onHover { hovering in
            hoveredRow = hovering ? agent.id : nil
        }
        .contextMenu {
            Button("Focus \(agent.source.capitalized)") { onFocus(agent) }
            if let title = agent.title {
                Button("Copy Title") { copyToClipboard(title) }
            }
            if let workspaceId = agent.workspaceId {
                Button("Open Workspace in Finder") {
                    openWorkspaceInFinder(workspaceId)
                }
            }
            Divider()
            if NotchHUDConfig.shared.mutedSources.contains(agent.source) {
                Button("Unmute \(agent.source)") {
                    NotchHUDConfig.shared.mutedSources.remove(agent.source)
                }
            } else {
                Button("Mute \(agent.source)") {
                    NotchHUDConfig.shared.mutedSources.insert(agent.source)
                }
            }
        }
    }

    // MARK: - Subviews

    private var composingFieldView: some View {
        HStack(spacing: 6) {
            TextField("Ask agent…", text: $promptText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .focused($promptFocused)
                .onSubmit { onSubmitPrompt() }
                .modifier(EscapeCancelsModifier { onCancelComposing() })
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.08))
                )
                .layoutPriority(0)

            Button(action: onSubmitPrompt) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help("Send prompt (Return)")
            .layoutPriority(1)

            Button(action: onCancelComposing) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Cancel (Esc)")
            .layoutPriority(1)
        }
    }

    private var agentDetailsAndActionsView: some View {
        HStack(spacing: 6) {
            agentTitleAndSubtitleView

            if agent.kind == .accessRequest || agent.kind == .waiting {
                approvalControlsView
            }

            hoverActionButtonsView
        }
    }

    private var agentTitleAndSubtitleView: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                agentTitleRow
                agentSubtitleRow
            }
            Spacer(minLength: 4)
            if let title = agent.title, agent.kind != .idle, !agent.kind.isOngoing {
                let clean = IslandMetrics.cleanHUDText(title)
                if !clean.isEmpty {
                    Text(clean)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onBeginComposing(agent) }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(0)
    }

    private var agentTitleRow: some View {
        HStack(spacing: 5) {
            if let ctx = agent.projectContext {
                Text(ctx.project)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let branch = ctx.branch {
                    Text(branch)
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
                if let diff = ctx.diffStat {
                    Text(diff)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(Color.green.opacity(0.9))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.green.opacity(0.12))
                        )
                        .lineLimit(1)
                }
            } else {
                Text(agent.source)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var agentSubtitleRow: some View {
        HStack(spacing: 5) {
            if agent.kind == .failed, let reason = agent.message {
                Text(IslandMetrics.cleanHUDText(reason))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(Color(hex: AgentEventKind.failed.color))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let live = agent.title ?? agent.message,
                agent.kind.isOngoing,
                !IslandMetrics.cleanHUDText(live).isEmpty
            {
                Text(IslandMetrics.cleanHUDText(live))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(agent.kind.label)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            if NotchHUDConfig.shared.showElapsedTime,
                let startedAt = agent.startedAt,
                agent.kind.isOngoing
            {
                Text(IslandMetrics.elapsedLabel(since: startedAt, now: now))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    @ViewBuilder
    private var approvalControlsView: some View {
        inlineApprovalControls(agent: agent)
            .layoutPriority(1)
    }

    private var hoverActionButtonsView: some View {
        Group {
            let rowHovered = isRowHovered
            TactileRowButton(
                systemName: "arrow.up.right",
                helpText: "Focus \(agent.source)"
            ) {
                onFocus(agent)
            }
            .layoutPriority(1)
            .opacity(rowHovered ? 1 : 0)
            .animation(
                rowHovered ? .easeOut(duration: 0.12) : .easeOut(duration: 0.06), value: rowHovered)

            TactileRowButton(
                systemName: "stop.fill",
                color: .red,
                helpText: "Stop \(agent.source)"
            ) {
                if let paneId = IslandMetrics.actionablePaneId(
                    paneId: agent.paneId, source: agent.source)
                {
                    AgentEventManager.shared.stop(paneId: paneId)
                }
            }
            .layoutPriority(1)
            .opacity(rowHovered ? 1 : 0)
            .animation(
                rowHovered ? .easeOut(duration: 0.12) : .easeOut(duration: 0.06), value: rowHovered)

            TactileRowButton(
                systemName: "eye",
                helpText: "View live output + git diff"
            ) {
                PeekPanelController.shared.show(agent: agent, adapter: adapter)
            }
            .layoutPriority(1)
            .opacity(rowHovered ? 1 : 0)
            .animation(
                rowHovered ? .easeOut(duration: 0.12) : .easeOut(duration: 0.06), value: rowHovered)

            TactileRowButton(
                systemName: "safari",
                helpText: "Open session in browser (Chrome / Dia)"
            ) {
                let slug = agent.projectContext?.project ?? agent.source
                let clean = StandaloneAgentDispatcher.cleanAgentName(
                    from: agent.paneId ?? agent.source)
                RichSessionViewer.openInBrowser(
                    agentName: clean.isEmpty ? agent.source : clean,
                    projectSlug: slug,
                    cwd: agent.cwd,
                    isWorking: agent.kind == .progress || agent.kind == .started,
                    sessionPath: agent.sessionPath
                )
            }
            .layoutPriority(1)
            .opacity(rowHovered ? 1 : 0)
            .animation(
                rowHovered ? .easeOut(duration: 0.12) : .easeOut(duration: 0.06), value: rowHovered)
        }
    }

    @ViewBuilder
    private func inlineApprovalControls(agent: AgentSnapshot) -> some View {
        let effectivePaneId =
            IslandMetrics.actionablePaneId(paneId: agent.paneId, source: agent.source)
            ?? "standalone:\(agent.source)"
        let controls = agent.approval
        let resolving = AgentEventManager.shared.isResolving(paneId: effectivePaneId)

        if controls.isYesNo {
            approvalActionButton(
                systemName: "checkmark.circle.fill", color: .green, help: "Approve",
                disabled: resolving
            ) {
                AgentEventManager.shared.approve(paneId: effectivePaneId)
            }
            approvalActionButton(
                systemName: "xmark.circle.fill", color: .red, help: "Deny",
                disabled: resolving
            ) {
                AgentEventManager.shared.deny(paneId: effectivePaneId)
            }
        } else if controls.isMulti {
            let labels = controls.displayedLabels()
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                let optionText =
                    controls.choices.indices.contains(index)
                    ? controls.choices[index] : "Option \(label)"
                approvalActionButton(
                    label: Text(label),
                    color: queueSelections[effectivePaneId]?.contains(
                        IslandMetrics.ApprovalControls.optionNumber(forIndex: index)
                    ) == true ? .green : .white.opacity(0.6),
                    help: optionText,
                    disabled: false,
                    accessibilityLabel: optionText
                ) {
                    queueSelections[effectivePaneId] = IslandMetrics.ApprovalControls.toggling(
                        queueSelections[effectivePaneId] ?? [], index: index)
                }
            }
            let overflow = controls.overflowCount()
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
            }
            approvalActionButton(
                systemName: "checkmark.circle.fill", color: .green, help: "Submit",
                disabled: resolving
            ) {
                let numbers = IslandMetrics.ApprovalControls.selectionNumbers(
                    queueSelections[effectivePaneId] ?? [])
                AgentEventManager.shared.approveMulti(
                    paneId: effectivePaneId, selections: numbers)
                queueSelections.removeValue(forKey: effectivePaneId)
            }
        } else {
            let labels = controls.displayedLabels()
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                let optionText =
                    controls.choices.indices.contains(index)
                    ? controls.choices[index] : "Option \(label)"
                approvalActionButton(
                    label: Text(label),
                    color: .white,
                    help: optionText,
                    disabled: resolving,
                    accessibilityLabel: optionText
                ) {
                    let choiceNum = IslandMetrics.ApprovalControls.optionNumber(forIndex: index)
                    AgentEventManager.shared.approveChoice(
                        paneId: effectivePaneId, choice: choiceNum)
                }
            }
            let overflow = controls.overflowCount()
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
            }
            if controls.optionLabels.isEmpty {
                approvalActionButton(
                    systemName: "checkmark.circle.fill", color: .green, help: "Approve",
                    disabled: resolving
                ) {
                    AgentEventManager.shared.approve(paneId: effectivePaneId)
                }
            }
        }

        Button(action: { onFocus(agent) }) {
            Image(systemName: "terminal.fill").font(.system(size: 9))
                .foregroundColor(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .help("Focus \(agent.source) window")
        .accessibilityLabel("Focus \(agent.source)")
    }

    private func openWorkspaceInFinder(_ workspaceId: String) {
        var url: URL?
        if workspaceId.hasPrefix("/") {
            url = URL(fileURLWithPath: workspaceId)
        } else if let cwd = ProcessInfo.processInfo.environment["PWD"] {
            url = URL(fileURLWithPath: cwd)
        }
        let target = url ?? URL(fileURLWithPath: NSHomeDirectory())
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}
