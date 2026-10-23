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
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    )
            }
            actionRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BantayTheme.statusAttention.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(BantayTheme.statusAttention.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(agent.source) needs approval: \(status.headline)")
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(BantayTheme.statusAttention)
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
            riskBadge
        }
    }

    private var riskBadge: some View {
        let (label, color): (String, Color) = {
            switch status.risk {
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
        if let tool = status.tool, !tool.isEmpty { return status.headline }
        return nil
    }

    @ViewBuilder
    private var actionRow: some View {
        let controls = agent.approval
        HStack(spacing: 8) {
            if controls.isYesNo {
                primaryButton(title: "Allow Once", icon: "checkmark") {
                    manager.approve(paneId: paneId)
                }
                secondaryButton(title: "Review", icon: "doc.text.magnifyingglass") {
                    onReview()
                }
                denyButton {
                    manager.deny(paneId: paneId)
                }
            } else if controls.isMulti {
                multiButtons(controls: controls)
                secondaryButton(title: "Review", icon: "doc.text.magnifyingglass") {
                    onReview()
                }
            } else {
                choiceButtons(controls: controls)
                secondaryButton(title: "Review", icon: "doc.text.magnifyingglass") {
                    onReview()
                }
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

    private func choiceButtons(
        controls: IslandMetrics.ApprovalControls
    ) -> some View {
        let labels = controls.displayedLabels()
        return ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
            let optionText =
                controls.choices.indices.contains(index)
                ? controls.choices[index] : "Option \(label)"
            Button {
                let number = IslandMetrics.ApprovalControls.optionNumber(forIndex: index)
                manager.approveChoice(paneId: paneId, choice: number)
            } label: {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .help(optionText)
            .accessibilityLabel("Choose \(optionText)")
        }
    }

    private func multiButtons(
        controls: IslandMetrics.ApprovalControls
    ) -> some View {
        let labels = controls.displayedLabels()
        return HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                let number = IslandMetrics.ApprovalControls.optionNumber(forIndex: index)
                let selected = queueSelections[paneId]?.contains(number) == true
                let optionText =
                    controls.choices.indices.contains(index)
                    ? controls.choices[index] : "Option \(label)"
                Button {
                    queueSelections[paneId] =
                        IslandMetrics.ApprovalControls.toggling(
                            queueSelections[paneId] ?? [], index: index)
                } label: {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(selected ? .black : .white)
                        .frame(width: 32, height: 32)
                        .background(
                            selected ? BantayTheme.statusCompleted : Color.white.opacity(0.1),
                            in: Circle())
                }
                .buttonStyle(.plain)
                .help(optionText)
                .accessibilityLabel("Toggle \(optionText)")
            }
            let numbers = IslandMetrics.ApprovalControls.selectionNumbers(
                queueSelections[paneId] ?? [])
            Button {
                manager.approveMulti(paneId: paneId, selections: numbers)
                queueSelections.removeValue(forKey: paneId)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Text("Submit")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(BantayTheme.statusCompleted, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Submit selected options")
            .accessibilityLabel("Submit selected options")
        }
    }
}
