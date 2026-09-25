import AppKit
import SwiftUI

/// Visual multi-agent activity timeline rendering real-time working bursts, tool calls, and milestones.
struct MultiAgentTimelineView: View {
    @ObservedObject private var store = MultiAgentTimelineStore.shared
    @State private var selectedAgent: String = "all"
    // 1 hour default
    @State private var selectedSpan: TimeInterval = 3600

    init() {}

    var body: some View {
        VStack(spacing: 6) {
            filterHeader

            if displaySegments.isEmpty {
                emptyTimelineView
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 4) {
                        ForEach(displaySegments.reversed()) { segment in
                            timelineRow(segment)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filterHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(BantayTheme.statusWorking)

            Text("Timeline")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(BantayTheme.textPrimary)

            Spacer()

            // Agent selector
            let agents = store.recordedAgents()
            if !agents.isEmpty {
                Menu {
                    Button("All Agents") { selectedAgent = "all" }
                    ForEach(agents, id: \.self) { agent in
                        Button(agent.capitalized) { selectedAgent = agent }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(selectedAgent == "all" ? "All" : selectedAgent.capitalized)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(BantayTheme.textSecondary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(BantayTheme.textTertiary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(BantayTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: BantayTheme.radiusSmall))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    private var displaySegments: [TimelineSegment] {
        store.filteredSegments(
            agent: selectedAgent == "all" ? nil : selectedAgent,
            span: selectedSpan
        )
    }

    private func timelineRow(_ segment: TimelineSegment) -> some View {
        HStack(spacing: 7) {
            // Status dot
            Circle()
                .fill(Color(hex: segment.kind.color))
                .frame(width: 7, height: 7)

            // Agent name
            Text(segment.agentName)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(BantayTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 72, maxWidth: 96, alignment: .leading)

            // Tool badge if available
            if let tool = segment.toolName, !tool.isEmpty {
                Text(tool)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(BantayTheme.statusWorking)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(BantayTheme.statusWorking.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            // Title / action
            Text(segment.title)
                .font(.system(size: 9.5, weight: .regular))
                .foregroundColor(BantayTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Duration tag
            Text(segment.formattedDuration)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(BantayTheme.textTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: BantayTheme.radiusSmall, style: .continuous)
                .fill(BantayTheme.cardBackground)
        )
    }

    private var emptyTimelineView: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 18))
                .foregroundColor(BantayTheme.textTertiary)
            Text("No agent activity recorded")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(BantayTheme.textSecondary)
            Text("Active runs, tool executions, and approvals will appear here.")
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(BantayTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
    }
}
