import Foundation

/// A discrete activity interval or milestone for an agent in the multi-agent timeline.
struct TimelineSegment: Identifiable, Equatable, Sendable {
    let id: UUID
    let agentName: String
    let project: String?
    let kind: AgentEventKind
    let title: String
    let toolName: String?
    let startTime: Date
    var endTime: Date?
    var tokens: Int?

    init(
        id: UUID = UUID(),
        agentName: String,
        project: String? = nil,
        kind: AgentEventKind,
        title: String,
        toolName: String? = nil,
        startTime: Date = Date(),
        endTime: Date? = nil,
        tokens: Int? = nil
    ) {
        self.id = id
        self.agentName = agentName
        self.project = project
        self.kind = kind
        self.title = title
        self.toolName = toolName
        self.startTime = startTime
        self.endTime = endTime
        self.tokens = tokens
    }

    /// Elapsed duration of this segment in seconds.
    var duration: TimeInterval {
        let end = endTime ?? Date()
        return max(end.timeIntervalSince(startTime), 0)
    }

    /// Short formatted duration string (e.g. "14s" or "3m").
    var formattedDuration: String {
        let secs = Int(duration)
        if secs < 60 {
            return "\(secs)s"
        } else {
            return "\(secs / 60)m"
        }
    }
}

/// Stores and manages continuous activity intervals across all active and recent agents.
@MainActor
final class MultiAgentTimelineStore: ObservableObject {
    static let shared = MultiAgentTimelineStore()

    @Published private(set) var segments: [TimelineSegment] = []
    private var activeSegmentIDs: [String: UUID] = [:]

    init() {}

    /// Records an agent status transition or execution milestone.
    func recordEvent(
        agentName: String,
        project: String? = nil,
        kind: AgentEventKind,
        title: String,
        tool: String? = nil,
        now: Date = Date()
    ) {
        // Close prior active segment for this agent if state changed
        if let priorID = activeSegmentIDs.removeValue(forKey: agentName),
            let idx = segments.firstIndex(where: { $0.id == priorID })
        {
            if segments[idx].endTime == nil {
                segments[idx].endTime = max(now, segments[idx].startTime)
            }
        }

        let newSegment = TimelineSegment(
            agentName: agentName,
            project: project,
            kind: kind,
            title: title,
            toolName: tool,
            startTime: now,
            endTime: (kind == .completed || kind == .failed) ? now : nil
        )

        segments.append(newSegment)

        if kind.isOngoing || kind == .accessRequest || kind == .waiting {
            activeSegmentIDs[agentName] = newSegment.id
        }

        // Cap rolling segments at 200 items
        if segments.count > 200 {
            segments.removeFirst(segments.count - 200)
        }
    }

    /// Returns all unique agent names present in the recorded timeline.
    func recordedAgents() -> [String] {
        var seen = Set<String>()
        var list: [String] = []
        for segment in segments {
            if !seen.contains(segment.agentName) {
                seen.insert(segment.agentName)
                list.append(segment.agentName)
            }
        }
        return list.sorted()
    }

    /// Returns segments filtered by agent name and maximum lookback span.
    func filteredSegments(
        agent: String? = nil,
        span: TimeInterval? = nil,
        now: Date = Date()
    ) -> [TimelineSegment] {
        segments.filter { segment in
            if let agent, !agent.isEmpty, agent != "all", segment.agentName != agent {
                return false
            }
            if let span, span > 0 {
                let cutoff = now.addingTimeInterval(-span)
                if (segment.endTime ?? segment.startTime) < cutoff {
                    return false
                }
            }
            return true
        }
    }

    /// Clears recorded segments (e.g. on test or session reset).
    func reset() {
        segments.removeAll()
        activeSegmentIDs.removeAll()
    }
}
