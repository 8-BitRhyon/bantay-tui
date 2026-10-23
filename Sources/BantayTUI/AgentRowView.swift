import AppKit
import SwiftUI

/// Individual agent row within the expanded Notch HUD roster.
///
/// Two-line working rows (48pt) show project context plus a humanized activity
/// line; finished rows collapse to a single compact line (34pt). Clicking a
/// row focuses the agent's window; secondary actions live behind hover
/// affordances and the context menu. Approval prompts render as
/// `ApprovalCardView`, never as cramped row icons.
struct AgentRowView: View {
    let agent: AgentSnapshot
    let adapter: PlexerAdapter
    @Binding var hoveredRow: String?
    @Binding var composingPaneId: String?
    @Binding var promptText: String
    @FocusState.Binding var promptFocused: Bool
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

    /// Finished agents get a compact single line; active work gets two lines.
    private var isCompact: Bool {
        switch agent.kind {
        case .completed, .idle, .cancelled, .clear: return true
        case .accessRequest, .waiting, .progress, .started, .failed: return false
        }
    }

    private var rowHeight: CGFloat {
        isCompact ? IslandMetrics.idleRowHeight : IslandMetrics.workingRowHeight
    }

    private var status: HumanizedAgentStatus {
        AgentPresentation.status(for: agent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
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
                    rowContentView
                    hoverActionsView
                }
            }
            .padding(.horizontal, 16)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
            .onTapGesture { onFocus(agent) }
        }
        .background(isRowHovered ? Color.white.opacity(0.07) : Color.clear)
        .modifier(AgentRowAccessibility(agent: agent))
        .onHover { hovering in
            hoveredRow = hovering ? agent.id : nil
        }
        .contextMenu {
            Button("Focus \(agent.source.capitalized)") { onFocus(agent) }
            Button("Review live output") {
                PeekPanelController.shared.show(agent: agent, adapter: adapter)
            }
            if agent.kind == .waiting || agent.kind == .completed
                || agent.kind == .progress || agent.kind == .started
            {
                Button("Reply to agent") { onBeginComposing(agent) }
            }
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

    private var rowContentView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if let ctx = agent.projectContext {
                    Text(ctx.project)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let branch = ctx.branch {
                        Text(branch)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                    if let diff = ctx.diffStat {
                        Text(diff)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(Color.green.opacity(0.9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.green.opacity(0.12))
                            )
                            .lineLimit(1)
                    }
                } else {
                    Text(agent.source)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if NotchHUDConfig.shared.showElapsedTime,
                    let startedAt = agent.startedAt,
                    agent.kind.isOngoing
                {
                    Text(IslandMetrics.elapsedLabel(since: startedAt, now: now))
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            if !isCompact {
                Text(status.headline)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(
                        agent.kind == .failed
                            ? Color(hex: AgentEventKind.failed.color)
                            : .white.opacity(0.75)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(0)
    }

    /// Hover affordances only: an explicit Open button plus an overflow menu.
    /// Stop, browser view, mute, and diagnostics moved out of the row.
    private var hoverActionsView: some View {
        HStack(spacing: 2) {
            TactileRowButton(
                systemName: "arrow.up.right",
                helpText: "Focus \(agent.source)"
            ) {
                onFocus(agent)
            }
            .layoutPriority(1)
            .opacity(isRowHovered ? 1 : 0)
            .animation(
                isRowHovered ? .easeOut(duration: 0.12) : .easeOut(duration: 0.06),
                value: isRowHovered)

            Menu {
                Button("Review live output + git diff") {
                    PeekPanelController.shared.show(agent: agent, adapter: adapter)
                }
                if agent.kind == .waiting || agent.kind == .completed
                    || agent.kind == .progress || agent.kind == .started
                {
                    Button("Reply to agent") { onBeginComposing(agent) }
                }
                Divider()
                Button("Stop \(agent.source)", role: .destructive) {
                    if let paneId = IslandMetrics.actionablePaneId(
                        paneId: agent.paneId, source: agent.source)
                    {
                        AgentEventManager.shared.stop(paneId: paneId)
                    }
                }
                Button("Open session in browser") {
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
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .layoutPriority(1)
            .opacity(isRowHovered ? 1 : 0)
            .animation(
                isRowHovered ? .easeOut(duration: 0.12) : .easeOut(duration: 0.06),
                value: isRowHovered
            )
            .help("More actions")
            .accessibilityLabel("More actions for \(agent.source)")
        }
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
