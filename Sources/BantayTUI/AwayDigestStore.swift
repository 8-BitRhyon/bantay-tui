import AppKit
import Foundation

/// Summary of agent events and resource spend that transpired while the user was away.
struct AwayDigest: Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let awayDuration: TimeInterval
    var completedTasks: [RecentCompletion]
    var failedTasks: [String]
    var approvalsAnswered: Int
    var approvalsPending: Int
    var tokensBurned: Int
    var costUSD: Double

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        awayDuration: TimeInterval,
        completedTasks: [RecentCompletion] = [],
        failedTasks: [String] = [],
        approvalsAnswered: Int = 0,
        approvalsPending: Int = 0,
        tokensBurned: Int = 0,
        costUSD: Double = 0.0
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.awayDuration = awayDuration
        self.completedTasks = completedTasks
        self.failedTasks = failedTasks
        self.approvalsAnswered = approvalsAnswered
        self.approvalsPending = approvalsPending
        self.tokensBurned = tokensBurned
        self.costUSD = costUSD
    }

    /// Finds the agent with the fastest completion duration during the away period.
    var fastestAgent: (agent: String, duration: TimeInterval)? {
        guard
            let best = completedTasks.min(by: { ($0.duration ?? 0) < ($1.duration ?? 0) }),
            let dur = best.duration
        else { return nil }
        return (best.source, dur)
    }

    /// Finds the agent with the slowest completion duration during the away period.
    var slowestAgent: (agent: String, duration: TimeInterval)? {
        guard
            let worst = completedTasks.max(by: { ($0.duration ?? 0) < ($1.duration ?? 0) }),
            let dur = worst.duration
        else { return nil }
        return (worst.source, dur)
    }

    /// Formatted duration string (e.g. "24m" or "1h 12m").
    var formattedDuration: String {
        let mins = max(Int(awayDuration / 60), 1)
        if mins < 60 {
            return "\(mins)m"
        } else {
            let hrs = mins / 60
            let rem = mins % 60
            return rem > 0 ? "\(hrs)h \(rem)m" : "\(hrs)h"
        }
    }

    /// Compact summary bullets for UI display and push notifications.
    var summaryLines: [String] {
        var lines: [String] = []
        if !completedTasks.isEmpty {
            let names = completedTasks.map(\.source).joined(separator: ", ")
            lines.append("\(completedTasks.count) completed (\(names))")
        }
        if !failedTasks.isEmpty {
            lines.append("\(failedTasks.count) failed (\(failedTasks.joined(separator: ", ")))")
        }
        if approvalsAnswered > 0 {
            lines.append("\(approvalsAnswered) approval(s) resolved via remote/phone")
        }
        if approvalsPending > 0 {
            lines.append("⚠️ \(approvalsPending) approval(s) currently waiting")
        }
        if costUSD > 0.001 || tokensBurned > 0 {
            let costStr = String(format: "$%.2f", costUSD)
            let tokStr = UsageTracker.compactTokens(tokensBurned)
            lines.append("\(costStr) spent (\(tokStr) tokens)")
        }
        if lines.isEmpty {
            lines.append("Background tasks remained quiet")
        }
        return lines
    }
}

/// Tracks user absence intervals (screen locked / display sleep) and aggregates background activity.
@MainActor
final class AwayDigestStore: ObservableObject {
    static let shared = AwayDigestStore()

    @Published private(set) var currentDigest: AwayDigest?
    @Published private(set) var isAway: Bool = false

    private var awayStartedAt: Date?
    private var baselineCostUSD: Double = 0.0
    private var baselineTokens: Int = 0
    private var awayCompletions: [RecentCompletion] = []
    private var awayFailures: [String] = []
    private var awayApprovalsAnswered: Int = 0

    init() {}

    /// Marks the start of an away period (e.g. screen lock or display sleep).
    func beginAway(
        now: Date = Date(),
        baselineCost: Double,
        baselineTokens: Int
    ) {
        guard !isAway else { return }
        isAway = true
        awayStartedAt = now
        baselineCostUSD = baselineCost
        self.baselineTokens = baselineTokens
        awayCompletions = []
        awayFailures = []
        awayApprovalsAnswered = 0
    }

    /// Records that an agent completed work while away.
    func recordCompletion(_ completion: RecentCompletion) {
        guard isAway else { return }
        awayCompletions.append(completion)
    }

    /// Records that an agent failed or hit an error while away.
    func recordFailure(agent: String, reason: String? = nil) {
        guard isAway else { return }
        let entry = reason != nil ? "\(agent): \(reason!)" : agent
        awayFailures.append(entry)
    }

    /// Records an approval resolved while away (e.g. phone approval via ntfy).
    func recordApprovalAnswered() {
        guard isAway else { return }
        awayApprovalsAnswered += 1
    }

    /// Ends the away period and compiles a digest if any significant activity occurred.
    func endAway(
        now: Date = Date(),
        currentCost: Double,
        currentTokens: Int,
        pendingApprovals: Int
    ) {
        guard isAway, let start = awayStartedAt else { return }
        isAway = false
        let duration = max(now.timeIntervalSince(start), 0)
        let costDelta = max(currentCost - baselineCostUSD, 0.0)
        let tokensDelta = max(currentTokens - baselineTokens, 0)

        // Only generate a digest if the user was away >= 30 seconds AND there was activity
        let hadActivity =
            !awayCompletions.isEmpty || !awayFailures.isEmpty
            || awayApprovalsAnswered > 0 || pendingApprovals > 0
            || costDelta > 0.001 || tokensDelta > 500

        if duration >= 30 && hadActivity {
            currentDigest = AwayDigest(
                startedAt: start,
                endedAt: now,
                awayDuration: duration,
                completedTasks: awayCompletions,
                failedTasks: awayFailures,
                approvalsAnswered: awayApprovalsAnswered,
                approvalsPending: pendingApprovals,
                tokensBurned: tokensDelta,
                costUSD: costDelta
            )
        }

        awayStartedAt = nil
        awayCompletions = []
        awayFailures = []
        awayApprovalsAnswered = 0
    }

    /// Dismisses the active digest card.
    func dismiss() {
        #if os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
        currentDigest = nil
    }
}
