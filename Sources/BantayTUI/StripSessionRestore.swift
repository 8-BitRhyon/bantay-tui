import Foundation

/// Durable strip layout: column order, widths, stacks (multi-window
/// columns), tabbed/pinned flags, and the focused window in each column.
///
/// Window ids are AX/CGWindowIDs, which change on restart; the snapshot
/// therefore stores stable descriptors (bundle id, title, agent cwd) and
/// re-binds them to freshly discovered windows at launch.
public struct StripLayoutSnapshot: Codable, Equatable, Sendable {
    public struct WindowRef: Codable, Equatable, Sendable {
        public var bundleID: String
        public var title: String
        public var agentCwd: String?

        public init(bundleID: String, title: String, agentCwd: String?) {
            self.bundleID = bundleID
            self.title = title
            self.agentCwd = agentCwd
        }
    }

    public struct ColumnRef: Codable, Equatable, Sendable {
        public var widthFraction: Double
        public var isTabbed: Bool
        public var isPinned: Bool
        public var focusedRow: Int
        public var windows: [WindowRef]

        public init(
            widthFraction: Double, isTabbed: Bool, isPinned: Bool,
            focusedRow: Int, windows: [WindowRef]
        ) {
            self.widthFraction = widthFraction
            self.isTabbed = isTabbed
            self.isPinned = isPinned
            self.focusedRow = focusedRow
            self.windows = windows
        }
    }

    public var columns: [ColumnRef]
    public var activeColumnIndex: Int
    public var savedAt: Date

    public init(columns: [ColumnRef], activeColumnIndex: Int, savedAt: Date = Date()) {
        self.columns = columns
        self.activeColumnIndex = activeColumnIndex
        self.savedAt = savedAt
    }

    /// Snapshot the live strip. Empty columns and windows are skipped.
    public static func capture(
        columns: [StripColumn], activeColumnIndex: Int, now: Date = Date()
    ) -> StripLayoutSnapshot {
        let refs = columns.compactMap { column -> ColumnRef? in
            guard !column.windows.isEmpty else { return nil }
            return ColumnRef(
                widthFraction: column.widthFraction,
                isTabbed: column.isTabbed,
                isPinned: column.isPinned,
                focusedRow: column.focusedRow,
                windows: column.windows.map {
                    WindowRef(
                        bundleID: $0.appBundleID,
                        title: $0.title,
                        agentCwd: $0.agentCwd)
                })
        }
        return StripLayoutSnapshot(
            columns: refs, activeColumnIndex: activeColumnIndex, savedAt: now)
    }

    /// Rebuild columns against the windows that exist now. Saved order,
    /// widths, stacks, tabs, and pins are kept; windows that vanished are
    /// dropped; windows never seen before are appended as new columns.
    public func restore(
        discovered: [StripWindowInfo]
    ) -> (columns: [StripColumn], activeColumnIndex: Int) {
        var remaining = discovered
        var restored: [StripColumn] = []

        for saved in columns {
            var windows: [StripWindowInfo] = []
            for ref in saved.windows {
                guard let match = Self.bestMatch(for: ref, in: remaining) else {
                    continue
                }
                windows.append(match.window)
                remaining.remove(at: match.index)
            }
            guard !windows.isEmpty else { continue }
            restored.append(
                StripColumn(
                    windows: windows,
                    widthFraction: saved.widthFraction,
                    isTabbed: saved.isTabbed,
                    focusedRow: min(max(saved.focusedRow, 0), windows.count - 1),
                    isPinned: saved.isPinned))
        }

        // Windows opened while the strip was down join the end, in scan order.
        for info in remaining {
            restored.append(
                StripColumn(
                    windows: [info],
                    widthFraction: 0.5,
                    isTabbed: false,
                    focusedRow: 0))
        }

        let active =
            restored.isEmpty
            ? 0 : min(max(activeColumnIndex, 0), restored.count - 1)
        return (restored, active)
    }

    /// Best remaining window for one saved descriptor. Exact bundle+title
    /// wins, then bundle+cwd, then bundle alone. Bundle-only matching keeps
    /// order stable for apps whose window titles change between launches.
    static func bestMatch(
        for ref: WindowRef, in candidates: [StripWindowInfo]
    ) -> (window: StripWindowInfo, index: Int)? {
        var best: (score: Int, index: Int)?
        for (index, info) in candidates.enumerated() {
            guard info.appBundleID == ref.bundleID else { continue }
            var score = 1
            if info.title == ref.title {
                score = 3
            } else if let cwd = ref.agentCwd,
                !cwd.isEmpty, info.agentCwd == cwd
            {
                score = 2
            }
            if best == nil || score > best!.score {
                best = (score, index)
            }
        }
        guard let best else { return nil }
        return (candidates[best.index], best.index)
    }
}

/// Per-display persistence for the strip layout. Each screen gets its own
/// snapshot, so a laptop and an external monitor never reshuffle each other.
public enum StripSessionStore {
    static let keyPrefix = "bantay.strip.layout."

    public static func load(
        displayKey: String, defaults: UserDefaults = .standard
    ) -> StripLayoutSnapshot? {
        guard let data = defaults.data(forKey: keyPrefix + displayKey) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StripLayoutSnapshot.self, from: data)
    }

    public static func save(
        _ snapshot: StripLayoutSnapshot, displayKey: String,
        defaults: UserDefaults = .standard
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: keyPrefix + displayKey)
    }

    /// Stable per-display storage key. CGDirectDisplayID survives launches;
    /// screen indexes do not.
    public static func displayKey(_ displayID: UInt32) -> String {
        "display-\(displayID)"
    }
}
