#if canImport(Testing)
    import Foundation
    import Testing

    @testable import BantayTUI

    @Suite("Ledger snapshots load off-main and scope in memory", .serialized)
    struct LedgerSnapshotTests {
        private func bucket(daysAgo: Int, tokens: Int, now: Date) -> OpenCodeUsageAdapter.DayBucket
        {
            let day = Calendar.current.date(
                byAdding: .day, value: -daysAgo,
                to: Calendar.current.startOfDay(for: now))!
            return OpenCodeUsageAdapter.DayBucket(
                dayStart: day, tokens: tokens,
                cost: Double(tokens) / 1_000_000.0 * 3.0,
                messages: tokens > 0 ? 1 : 0)
        }

        @Test("empty home yields an empty snapshot")
        func emptyHomeYieldsEmptySnapshot() async throws {
            let home =
                FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-ledger-empty-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(
                atPath: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: home) }
            let snapshot = await LedgerSnapshotCache.shared.snapshot(home: home)
            #expect(snapshot.lifetime == nil)
            #expect(snapshot.buckets.isEmpty)
            #expect(snapshot.revision == 0)
        }

        @Test("repeat loads hit the revision-gated cache")
        func repeatLoadsHitCache() async throws {
            // Empty home keeps this deterministic: no live ledger can move
            // the revision between the two loads on any machine.
            let home =
                FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-ledger-cache-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(
                atPath: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: home) }
            let first = await LedgerSnapshotCache.shared.snapshot(home: home)
            let second = await LedgerSnapshotCache.shared.snapshot(home: home)
            #expect(first == second)
        }

        @Test("scopes filter one cached snapshot in memory")
        func scopesFilterCachedSnapshot() {
            let now = Date()
            let snapshot = LedgerSnapshotData(
                lifetime: OpenCodeUsageAdapter.LifetimeTotals(
                    tokens: 600, cost: 0.002, sessions: 3),
                buckets: [
                    bucket(daysAgo: 0, tokens: 100, now: now),
                    bucket(daysAgo: 3, tokens: 200, now: now),
                    bucket(daysAgo: 30, tokens: 300, now: now),
                ],
                revision: 7)
            let life = ScopedLedger.summary(
                scope: .lifetime, snapshot: snapshot, now: now)
            #expect(life.tokens == 600)
            #expect(life.sessions == 3)
            #expect(life.activeDays == 3)
            let week = ScopedLedger.summary(scope: .week, snapshot: snapshot, now: now)
            #expect(week.tokens == 300)
            #expect(week.sessions == nil)
            let day = ScopedLedger.summary(scope: .day, snapshot: snapshot, now: now)
            #expect(day.tokens == 100)
        }
    }
#endif
