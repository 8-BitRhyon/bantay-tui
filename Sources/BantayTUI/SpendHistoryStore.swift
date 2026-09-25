import Foundation

/// A persistent daily record of AI model tokens and USD cost.
struct DailySpendRecord: Identifiable, Codable, Equatable, Sendable {
    var id: String { dateKey }
    let dateKey: String
    var totalCostUSD: Double
    var totalTokens: Int
    var inputTokens: Int
    var outputTokens: Int
    var cacheTokens: Int
    var costByAgent: [String: Double]
    var peakBurnRateTPM: Double

    init(
        dateKey: String,
        totalCostUSD: Double = 0.0,
        totalTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheTokens: Int = 0,
        costByAgent: [String: Double] = [:],
        peakBurnRateTPM: Double = 0.0
    ) {
        self.dateKey = dateKey
        self.totalCostUSD = totalCostUSD
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
        self.costByAgent = costByAgent
        self.peakBurnRateTPM = peakBurnRateTPM
    }
}

/// Stores, aggregates, and persists daily AI spend history across days and weeks.
@MainActor
final class SpendHistoryStore: ObservableObject {
    static let shared = SpendHistoryStore()

    @Published private(set) var dailyRecords: [String: DailySpendRecord] = [:]

    private let fileURL: URL

    init(customFileURL: URL? = nil) {
        if let customFileURL {
            self.fileURL = customFileURL
        } else {
            let appSupport =
                FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let bantayDir = appSupport.appendingPathComponent("Bantay-TUI", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: bantayDir, withIntermediateDirectories: true)
            self.fileURL = bantayDir.appendingPathComponent("spend-history.json")
        }
        load()
    }

    /// Key for date string (YYYY-MM-DD).
    static func dateKey(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// Records a usage snapshot into today's spend ledger.
    func recordUsage(
        snapshot: UsageSnapshot,
        peakTPM: Double = 0.0,
        date: Date = Date()
    ) {
        let key = Self.dateKey(for: date)
        var record = dailyRecords[key] ?? DailySpendRecord(dateKey: key)

        record.totalCostUSD = max(record.totalCostUSD, snapshot.costUSD)
        record.totalTokens = max(record.totalTokens, snapshot.totalTokens)
        record.inputTokens = max(record.inputTokens, snapshot.inputTokens)
        record.outputTokens = max(record.outputTokens, snapshot.outputTokens)
        record.cacheTokens = max(
            record.cacheTokens, snapshot.cacheReadTokens + snapshot.cacheWriteTokens)
        record.peakBurnRateTPM = max(record.peakBurnRateTPM, peakTPM)

        for (source, cost) in snapshot.costBySource {
            record.costByAgent[source] = max(record.costByAgent[source] ?? 0.0, cost)
        }

        dailyRecords[key] = record
        pruneAndSave(now: date)
    }

    /// Returns records for the last `count` days (default 7 days).
    func recentDays(count: Int = 7, now: Date = Date()) -> [DailySpendRecord] {
        guard count > 0 else { return [] }
        var results: [DailySpendRecord] = []
        let calendar = Calendar.current
        for offset in (0..<count).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let key = Self.dateKey(for: day)
            let record = dailyRecords[key] ?? DailySpendRecord(dateKey: key)
            results.append(record)
        }
        return results
    }

    /// Calculates projected daily spend and fraction of daily budget.
    func projectedRunRate(
        budget: Double,
        now: Date = Date()
    ) -> (projectedDayUSD: Double, fractionOfBudget: Double) {
        let key = Self.dateKey(for: now)
        let todayCost = dailyRecords[key]?.totalCostUSD ?? 0.0
        let calendar = Calendar.current
        let hour = Double(calendar.component(.hour, from: now))
        let minute = Double(calendar.component(.minute, from: now))
        let dayFraction = max((hour * 60 + minute) / 1440.0, 0.05)

        let projected = todayCost / dayFraction
        let fraction = budget > 0 ? min(max(projected / budget, 0), 2.0) : 0
        return (projected, fraction)
    }

    /// Sums total cost incurred over the last 7 calendar days.
    func totalPastWeekUSD(now: Date = Date()) -> Double {
        recentDays(count: 7, now: now).reduce(0.0) { $0 + $1.totalCostUSD }
    }

    private func pruneAndSave(now: Date) {
        // Keep last 30 days
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -30, to: now) else { return }
        let cutoffKey = Self.dateKey(for: cutoff)
        dailyRecords = dailyRecords.filter { $0.key >= cutoffKey }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(dailyRecords) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: DailySpendRecord].self, from: data)
        {
            dailyRecords = decoded
        }
    }
}
