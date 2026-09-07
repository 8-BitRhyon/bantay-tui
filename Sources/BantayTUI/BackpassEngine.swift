import Foundation

/// Headless engine implementing Kun Chen's Backpass text-gradient memory philosophy.
/// "You don't write AGENTS.md. You train it with gradient descent."
///
/// Backpass inspects multi-agent session interaction traces, computes text deltas
/// between agent assumptions and human corrections, and enforces a strict
/// **2-session evidence gate** before proposing directives for `AGENTS.md`.
public enum BackpassEngine {

    /// A single interaction turn extracted from an agent session transcript.
    public struct SessionInteraction: Equatable, Sendable, Identifiable {
        public let id: String
        public let sessionId: String
        public let agentSource: String
        public let toolName: String?
        public let userCorrection: String
        public let hadError: Bool
        public let timestamp: Date

        public init(
            id: String = UUID().uuidString,
            sessionId: String,
            agentSource: String,
            toolName: String? = nil,
            userCorrection: String,
            hadError: Bool = false,
            timestamp: Date = Date()
        ) {
            self.id = id
            self.sessionId = sessionId
            self.agentSource = agentSource
            self.toolName = toolName
            self.userCorrection = userCorrection
            self.hadError = hadError
            self.timestamp = timestamp
        }
    }

    /// A candidate rule proposed by the gradient descent synthesizer.
    public struct RuleCandidate: Equatable, Sendable, Identifiable {
        public let id: String
        public let instruction: String
        public let targetScope: String  // e.g. "build", "test", "formatting", "safety"
        public let evidenceSessionIds: Set<String>
        public let occurrenceCount: Int

        /// Strict evidence gate: must be confirmed across at least 2 independent sessions.
        public var hasMetEvidenceThreshold: Bool {
            evidenceSessionIds.count >= 2
        }

        public init(
            id: String,
            instruction: String,
            targetScope: String,
            evidenceSessionIds: Set<String>,
            occurrenceCount: Int
        ) {
            self.id = id
            self.instruction = instruction
            self.targetScope = targetScope
            self.evidenceSessionIds = evidenceSessionIds
            self.occurrenceCount = occurrenceCount
        }
    }

    /// Evaluates candidate instruction against interaction history and enforces the 2-session evidence gate.
    /// Rejects single-session flukes (returns nil); approves recurring patterns across >= 2 sessions.
    public static func evaluateCandidate(
        id: String,
        instruction: String,
        scope: String,
        interactions: [SessionInteraction]
    ) -> RuleCandidate? {
        let matching = interactions.filter { interaction in
            let lowerText = interaction.userCorrection.lowercased()
            let lowerInst = instruction.lowercased()
            return lowerText.contains(lowerInst) || lowerInst.contains(lowerText)
                || (interaction.hadError && !lowerText.isEmpty)
        }

        let sessionIds = Set(matching.map { $0.sessionId })
        let candidate = RuleCandidate(
            id: id,
            instruction: instruction,
            targetScope: scope,
            evidenceSessionIds: sessionIds,
            occurrenceCount: matching.count
        )

        // Enforce the 2-session evidence gate
        guard candidate.hasMetEvidenceThreshold else {
            return nil
        }
        return candidate
    }

    /// Formats a proposed markdown directive line for insertion into `AGENTS.md`.
    public static func formatAgentsDirective(candidate: RuleCandidate) -> String {
        "- **[\(candidate.targetScope.uppercased())]**: \(candidate.instruction) *(Validated across \(candidate.evidenceSessionIds.count) sessions)*"
    }

    /// Aggregates interactions and generates rule candidates meeting the evidence threshold.
    public static func synthesizeRules(from interactions: [SessionInteraction]) -> [RuleCandidate] {
        // Group by userCorrection keyword or tool pattern
        var grouped: [String: [SessionInteraction]] = [:]
        for item in interactions {
            let key = item.userCorrection.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            grouped[key, default: []].append(item)
        }

        var results: [RuleCandidate] = []
        for (correction, items) in grouped {
            let sessionIds = Set(items.map { $0.sessionId })
            if sessionIds.count >= 2 {
                let candidate = RuleCandidate(
                    id: UUID().uuidString,
                    instruction: correction,
                    targetScope: "policy",
                    evidenceSessionIds: sessionIds,
                    occurrenceCount: items.count
                )
                results.append(candidate)
            }
        }
        return results.sorted { $0.occurrenceCount > $1.occurrenceCount }
    }
}
