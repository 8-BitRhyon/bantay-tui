import SwiftUI

/// Unified Stage 2 approval card for the Agents inbox. One card per blocked
/// agent: exact request, risk badge, queue position, and full-height actions.
/// Replaces the tiny icon-only inline approval buttons in roster rows.
struct ApprovalCardView: View {
    let agent: AgentSnapshot
    let queueIndex: Int
    let queueTotal: Int
    @Binding var queueSelections: [String: Set<Int>]
    let onReview: () -> Void
    let onFocus: () -> Void

    @ObservedObject private var manager = AgentEventManager.shared

    private var paneId: String {
        IslandMetrics.actionablePaneId(paneId: agent.paneId, source: agent.source)
            ?? agent.id
    }

    private var resolving: Bool {
        manager.isResolving(paneId: paneId)
    }

    private var status: HumanizedAgentStatus {
        AgentPresentation.status(for: agent)
    }

    private var canApprove: Bool {
        guard agent.kind == .accessRequest, agent.approvalActionable else { return false }
        if let variance = agent.variance,
            variance == .choices || variance == .multi,
            (agent.choices?.count ?? 0) < 2
        {
            return false
        }
        return true
    }

    private var headerTitle: String {
        if canApprove { return "Approval needed" }
        if agent.kind == .waiting { return "Waiting for you" }
        if !agent.approvalActionable { return "Review this request" }
        return "Agent needs input"
    }

    private var projectLabel: String? {
        guard let project = agent.projectContext?.project, !project.isEmpty,
            project.lowercased() != agent.source.lowercased()
        else { return nil }
        return project
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            Text(status.headline)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
            if let request = requestText {
                Text(request)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    )
            }
            if !choiceOptions.isEmpty {
                choiceList
            }
            actionRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    (canApprove ? BantayTheme.statusAttention : BantayTheme.textTertiary)
                        .opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    (canApprove ? BantayTheme.statusAttention : BantayTheme.borderSubtle)
                        .opacity(canApprove ? 0.4 : 0.3),
                    lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(agent.source) \(headerTitle.lowercased()): \(status.headline)")
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Image(systemName: canApprove ? "exclamationmark.triangle.fill" : "hourglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(
                    canApprove ? BantayTheme.statusAttention : BantayTheme.textTertiary)
            Text(headerTitle.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(
                    canApprove ? BantayTheme.statusAttention : BantayTheme.textTertiary)
            Text(agent.source.capitalized)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
            if let projectLabel {
                Text("· \(projectLabel)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            if let branch = agent.projectContext?.branch {
                Text(branch)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if queueTotal > 1 {
                Text("\(queueIndex + 1) of \(queueTotal)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
            if canApprove { riskBadge }
        }
    }

    private var riskBadge: some View {
        let (label, color): (String, Color) = {
            switch agent.approvalRisk {
            case .high: return ("High risk", BantayTheme.statusFailed)
            case .medium: return ("Medium", BantayTheme.statusAttention)
            case .low: return ("Low", BantayTheme.textTertiary)
            }
        }()
        return Text(label.uppercased())
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var requestText: String? {
        if let detail = status.detail, !detail.isEmpty { return detail }
        if let title = agent.title,
            !IslandMetrics.isGenericApprovalText(title),
            !title.isEmpty
        {
            return title
        }
        if let message = agent.message,
            !IslandMetrics.isGenericApprovalText(message),
            !message.isEmpty
        {
            return message
        }
        return "No request text captured. Review the terminal before deciding."
    }

    private var choiceOptions: [String] {
        let controls = agent.approval
        guard !controls.isYesNo else { return [] }
        return Array(controls.choices.prefix(6))
    }

    private var choiceList: some View {
        VStack(spacing: 4) {
            ForEach(Array(choiceOptions.enumerated()), id: \.offset) { index, label in
                let number = IslandMetrics.ApprovalControls.optionNumber(forIndex: index)
                let isSelected =
                    agent.approval.isMulti
                    && queueSelections[paneId]?.contains(number) == true
                Button {
                    if agent.approval.isMulti {
                        queueSelections[paneId] =
                            IslandMetrics.ApprovalControls.toggling(
                                queueSelections[paneId] ?? [], index: index)
                    } else {
                        manager.approveChoice(paneId: paneId, choice: number)
                    }
                } label: {
                    HStack(spacing: 6) {
                        if agent.approval.isMulti {
                            Image(
                                systemName: isSelected
                                    ? "checkmark.square.fill" : "square"
                            )
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(
                                isSelected ? BantayTheme.statusCompleted : .white.opacity(0.5))
                        }
                        Text("\(number). \(label)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: IslandMetrics.approvalChoiceRowHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                isSelected
                                    ? BantayTheme.statusCompleted.opacity(0.18)
                                    : Color.white.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
                .help(label)
                .accessibilityLabel("Option \(number): \(label)")
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        let controls = agent.approval
        HStack(spacing: 8) {
            if canApprove {
                approvalActions(controls: controls)
            } else {
                waitingActions(controls: controls)
            }
            Spacer(minLength: 0)
            Button {
                onFocus()
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Focus agent window")
            .accessibilityLabel("Focus agent window")
        }
        .frame(minHeight: 36)
        .disabled(resolving)
        .opacity(resolving ? 0.5 : 1)
    }

    @ViewBuilder
    private func approvalActions(controls: IslandMetrics.ApprovalControls) -> some View {
        if controls.isMulti {
            submitButton
            reviewButton
        } else if controls.isYesNo {
            primaryButton(title: "Allow Once", icon: "checkmark") {
                manager.approve(paneId: paneId)
            }
            reviewButton
            denyButton {
                manager.deny(paneId: paneId)
            }
        } else {
            reviewButton
        }
    }

    @ViewBuilder
    private func waitingActions(controls: IslandMetrics.ApprovalControls) -> some View {
        if controls.isMulti {
            submitButton
        }
        reviewButton
        secondaryButton(title: "Open terminal", icon: "terminal") {
            onFocus()
        }
    }

    private var submitButton: some View {
        let numbers = IslandMetrics.ApprovalControls.selectionNumbers(
            queueSelections[paneId] ?? [])
        return Button {
            manager.approveMulti(paneId: paneId, selections: numbers)
            queueSelections.removeValue(forKey: paneId)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Text("Submit")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(numbers.isEmpty ? .white.opacity(0.4) : .black)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                numbers.isEmpty
                    ? Color.white.opacity(0.08) : BantayTheme.statusCompleted,
                in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(numbers.isEmpty)
        .help("Submit selected options")
        .accessibilityLabel("Submit selected options")
    }

    private var reviewButton: some View {
        secondaryButton(title: "Review", icon: "doc.text.magnifyingglass") {
            onReview()
        }
    }

    private func primaryButton(
        title: String, icon: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(BantayTheme.statusCompleted, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("\(title) (Y)")
        .accessibilityLabel("\(title). Shortcut Y.")
    }

    private func secondaryButton(
        title: String, icon: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func denyButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                Text("Deny")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(BantayTheme.statusFailed)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(BantayTheme.statusFailed.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Deny request (N)")
        .accessibilityLabel("Deny request. Shortcut N.")
    }
}
