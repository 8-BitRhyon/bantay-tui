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
                }
                .frame(maxWidth: .infinity)
                .frame(height: 92)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(historyStore.sessions) { session in
                            HStack(spacing: 8) {
                                Image(systemName: "terminal.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.cyan)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(session.title)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.white)
                                        .lineLimit(1)

                                    HStack(spacing: 6) {
                                        Text(session.agentName.capitalized)
                                            .font(.system(size: 8, weight: .semibold))
                                            .foregroundColor(.cyan)
                                        Text("•")
                                            .font(.system(size: 8))
                                            .foregroundColor(.white.opacity(0.3))
                                        Text("\(session.totalTokens) tok")
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.6))
                                        Text("•")
                                            .font(.system(size: 8))
                                            .foregroundColor(.white.opacity(0.3))
                                        Text(String(format: "$%.2f", session.costUSD))
                                            .font(
                                                .system(
                                                    size: 8, weight: .bold, design: .monospaced)
                                            )
                                            .foregroundColor(.green.opacity(0.8))
                                    }
                                }
                                Spacer()

                                Text(session.status)
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.green.opacity(0.2)))
                                    .foregroundColor(.green)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }
}
