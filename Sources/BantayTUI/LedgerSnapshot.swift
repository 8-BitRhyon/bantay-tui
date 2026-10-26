import Foundation

/// Which spend window the ledger section shows. Every scope derives from one
/// cached 400-day bucket set, so switching scopes is pure in-memory math and
/// never touches SQLite.
enum LedgerScope: String, Sendable, CaseIterable {
    case lifetime
    case week
    case day
}

/// One off-main load of the OpenCode ledger: lifetime totals plus the
/// per-day buckets every scope filters from. The SQLite scan behind this
/// takes seconds on large ledgers, so views must never build it in `body`.
struct LedgerSnapshotData: Equatable, Sendable {
    let lifetime: OpenCodeUsageAdapter.LifetimeTotals?
    let buckets: [OpenCodeUsageAdapter.DayBucket]
    let revision: UInt64

    static let empty = LedgerSnapshotData(
        lifetime: nil, buckets: [], revision: 0)
}

/// Pure scope math over a cached snapshot. No disk, no clock surprises:
/// callers pass `now` so tests pin the day boundary.
enum ScopedLedger: Sendable {
    struct Summary: Equatable, Sendable {
        let tokens: Int
        let cost: Double
        let sessions: Int?
        let activeDays: Int
        let streakCurrent: Int
        let streakLongest: Int
    }

    static func summary(
        scope: LedgerScope, snapshot: LedgerSnapshotData, now: Date = Date()
    ) -> Summary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let windowStart: Date?
        switch scope {
        case .lifetime:
            windowStart = nil
        case .week:
            windowStart = calendar.date(byAdding: .day, value: -6, to: today)
        case .day:
            windowStart = today
        }
        let kept =
            windowStart == nil
            ? snapshot.buckets
            : snapshot.buckets.filter { $0.dayStart >= windowStart! }
        let tokens = kept.reduce(0) { $0 + $1.tokens }
        let cost = kept.reduce(0.0) { $0 + $1.cost }
        let activeDays = kept.filter { $0.messages > 0 }.map(\.dayStart)
        let streak = IslandMetrics.usageStreak(activeDays: activeDays, now: now)
        switch scope {
        case .lifetime:
            return Summary(
                tokens: snapshot.lifetime?.tokens ?? tokens,
                cost: snapshot.lifetime?.cost ?? cost,
                sessions: snapshot.lifetime?.sessions,
                activeDays: activeDays.count,
                streakCurrent: streak.current,
                streakLongest: streak.longest)
        case .week, .day:
            return Summary(
                tokens: tokens, cost: cost, sessions: nil,
                activeDays: activeDays.count,
                streakCurrent: streak.current,
                streakLongest: streak.longest)
        }
    }
}

/// Revision-gated ledger cache. The snapshot rebuilds only when the ledger
/// files move; repeat loads while the user tabs around return the cached
/// value without touching SQLite.
actor LedgerSnapshotCache {
    static let shared = LedgerSnapshotCache()

    private var cachedHome: String?
    private var cached: LedgerSnapshotData?

    init() {}

    func snapshot(home: String = NSHomeDirectory()) async -> LedgerSnapshotData {
        let revision = OpenCodeUsageAdapter.ledgerRevision(home: home)
        if let cached, cachedHome == home, cached.revision == revision {
            return cached
        }
        let loaded = await Task.detached(priority: .utility) {
            Self.load(home: home, revision: revision)
        }.value
        cachedHome = home
        cached = loaded
        return loaded
    }

    func invalidate() {
        cached = nil
        cachedHome = nil
    }

    private nonisolated static func load(
        home: String, revision: UInt64
    ) -> LedgerSnapshotData {
        LedgerSnapshotData(
            lifetime: OpenCodeUsageAdapter.lifetimeTotals(home: home),
            buckets: OpenCodeUsageAdapter.dailyBuckets(days: 400, home: home),
            revision: revision)
    }
}
