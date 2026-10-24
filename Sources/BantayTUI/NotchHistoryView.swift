import AppKit
import SwiftUI

enum HistoryMode: String, CaseIterable, Identifiable {
    case timeline = "Timeline"
    case spend = "Spend"
    case quotas = "Quotas"
    case sessions = "Sessions"

    var id: String { rawValue }
}

struct NotchHistoryView: View {
    @Binding var historyMode: HistoryMode
    @ObservedObject private var historyStore = SessionHistoryStore.shared
    @State private var sessionSearch = ""
    @State private var sessionAgentFilter = "all"
    @State private var expandedSessionId: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(HistoryMode.allCases) { mode in
                    Button(action: {
                        #if os(macOS)
                            NSHapticFeedbackManager.defaultPerformer.perform(
                                .generic, performanceTime: .now)
                        #endif
                        withAnimation(BantayTheme.springSnappy) {
                            historyMode = mode
                        }
                    }) {
                        Text(mode.rawValue)
                            .font(.system(size: 9.5, weight: historyMode == mode ? .bold : .medium))
                            .foregroundColor(
                                historyMode == mode
                                    ? BantayTheme.textPrimary
                                    : BantayTheme.textTertiary
                            )
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                historyMode == mode
                                    ? BantayTheme.cardSelected
                                    : Color.clear
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)

            ScrollView(.vertical, showsIndicators: false) {
                switch historyMode {
                case .timeline:
                    MultiAgentTimelineView()
                case .spend:
                    SpendHistoryView()
                case .quotas:
                    ProviderQuotaView()
                case .sessions:
                    sessionsListView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sessionsListView: some View {
        VStack(spacing: 0) {
            if historyStore.sessions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.35))
                    Text("No agent sessions recorded yet")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                    Text("Sessions appear when an agent finishes or fails.")
                        .font(.system(size: 9.5))
                        .foregroundColor(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 92)
            } else {
                sessionsToolbar
                if filteredSessions.isEmpty {
                    Text("No sessions match this filter")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                } else {
                    sessionsSummary
                    ScrollView {
                        LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                            ForEach(sessionDayGroups, id: \.label) { group in
                                Section {
                                    ForEach(group.sessions) { session in
                                        sessionRow(session)
                                    }
                                } header: {
                                    Text(group.label.uppercased())
                                        .font(.system(size: 8.5, weight: .bold))
                                        .foregroundColor(.white.opacity(0.4))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 2)
                                        .background(BantayTheme.cardBackground.opacity(0.9))
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
    }

    // MARK: - Sessions filtering and grouping

    private var sessionAgents: [String] {
        Array(Set(historyStore.sessions.map(\.agentName))).sorted()
    }

    private var filteredSessions: [AgentSessionRecord] {
        let query = sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return historyStore.sessions.filter { session in
            if sessionAgentFilter != "all", session.agentName != sessionAgentFilter {
                return false
            }
            guard !query.isEmpty else { return true }
            return session.title.lowercased().contains(query)
                || session.agentName.lowercased().contains(query)
                || (session.project ?? "").lowercased().contains(query)
                || (session.branch ?? "").lowercased().contains(query)
        }
    }

    private struct SessionDayGroup {
        let label: String
        let dayStart: Date
        let sessions: [AgentSessionRecord]
    }

    private var sessionDayGroups: [SessionDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredSessions) {
            calendar.startOfDay(for: $0.startTime)
        }
        return grouped.map { dayStart, sessions in
            SessionDayGroup(
                label: IslandMetrics.sessionDayLabel(for: dayStart),
                dayStart: dayStart,
                sessions: sessions.sorted { $0.startTime > $1.startTime })
        }
        .sorted { $0.dayStart > $1.dayStart }
    }

    private var sessionsToolbar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
            TextField("Search sessions", text: $sessionSearch)
                .font(.system(size: 10))
                .foregroundColor(.white)
                .textFieldStyle(.plain)
            if !sessionSearch.isEmpty {
                Button {
                    sessionSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            Menu {
                Button("All agents") { sessionAgentFilter = "all" }
                ForEach(sessionAgents, id: \.self) { agent in
                    Button(agent.capitalized) { sessionAgentFilter = agent }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(sessionAgentFilter == "all" ? "All" : sessionAgentFilter.capitalized)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.07), in: Capsule())
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var sessionsSummary: some View {
        let totalCost = filteredSessions.reduce(0) { $0 + $1.costUSD }
        let totalTokens = filteredSessions.reduce(0) { $0 + $1.totalTokens }
        let failures = filteredSessions.filter(\.isFailed).count
        return HStack(spacing: 6) {
            Text("\(filteredSessions.count) sessions")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            Text("· \(IslandMetrics.compactTokenCount(totalTokens)) tok")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))
            Text("· $\(String(format: "%.2f", totalCost))")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.green.opacity(0.8))
            if failures > 0 {
                Text("· \(failures) failed")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(BantayTheme.statusFailed.opacity(0.9))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .accessibilityLabel(
            "\(filteredSessions.count) sessions, \(totalTokens) tokens, $\(String(format: "%.2f", totalCost))"
        )
    }

    // MARK: - Session rows with transcript, reveal, and copy actions

    @ViewBuilder
    private func sessionRow(_ session: AgentSessionRecord) -> some View {
        let expanded = expandedSessionId == session.id
        VStack(spacing: 0) {
            Button {
                withAnimation(BantayTheme.springSnappy) {
                    expandedSessionId = expanded ? nil : session.id
                }
            } label: {
                HStack(spacing: 8) {
                    Image(
                        systemName: session.isFailed
                            ? "xmark.octagon.fill" : "checkmark.circle.fill"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(
                        session.isFailed
                            ? BantayTheme.statusFailed : BantayTheme.statusCompleted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        sessionContextLine(session)
                        sessionStatsLine(session)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.3))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(session.agentName) session: \(session.title), \(session.status)")
            if expanded {
                HStack(spacing: 6) {
                    sessionActionButton(title: "Transcript", systemName: "doc.text") {
                        RichSessionViewer.openInBrowser(
                            agentName: session.agentName,
                            projectSlug: session.project ?? session.agentName,
                            cwd: session.cwd,
                            isWorking: false,
                            sessionPath: session.sessionPath)
                    }
                    if let cwd = session.cwd, !cwd.isEmpty {
                        sessionActionButton(title: "Reveal", systemName: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: cwd)
                            ])
                        }
                    }
                    sessionActionButton(title: "Copy", systemName: "doc.on.doc") {
                        copyToClipboard(
                            "\(session.title)\n\(session.agentName) · \(session.status) · $\(String(format: "%.2f", session.costUSD))"
                        )
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 7)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    session.isFailed
                        ? BantayTheme.statusFailed.opacity(0.08)
                        : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    session.isFailed
                        ? BantayTheme.statusFailed.opacity(0.3)
                        : Color.white.opacity(0.06),
                    lineWidth: 1)
        )
    }

    private func sessionContextLine(_ session: AgentSessionRecord) -> some View {
        HStack(spacing: 4) {
            Text(session.agentName.capitalized)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.cyan)
            if let project = session.project, !project.isEmpty {
                Text("· \(project)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                if let branch = session.branch, !branch.isEmpty {
                    Text(branch)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 4)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .lineLimit(1)
                }
            } else {
                Text("· project unknown")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }

    private func sessionStatsLine(_ session: AgentSessionRecord) -> some View {
        HStack(spacing: 4) {
            if session.durationSeconds > 0 {
                Text(
                    IslandMetrics.elapsedLabel(
                        since: Date(timeIntervalSinceNow: -session.durationSeconds),
                        now: Date())
                )
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                Text("·")
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.3))
            }
            Text("\(IslandMetrics.compactTokenCount(session.totalTokens)) tok")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
            Text("·")
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.3))
            Text(String(format: "$%.2f", session.costUSD))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.green.opacity(0.8))
            Text("·")
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.3))
            Text(session.status)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(
                    session.isFailed
                        ? BantayTheme.statusFailed : BantayTheme.statusCompleted)
        }
    }

    private func sessionActionButton(
        title: String, systemName: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
