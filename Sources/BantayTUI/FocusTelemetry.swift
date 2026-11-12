import Foundation

/// One focus attempt from the notch. The log is local-only and contains no
/// agent titles or prompt text; it exists to test the exact-focus wedge.
struct FocusEvent: Codable, Equatable, Sendable {
    enum Method: String, Codable, Sendable {
        case antigravityConversation
        case pane
        case standalone
        case unavailable
    }

    let timestamp: Date
    let agentID: String
    let source: String
    let sessionPath: String?
    let paneID: String?
    let method: Method
    let success: Bool
}

/// Append-only local focus log plus pure summary helpers for the alpha test.
enum FocusTelemetry {
    struct Summary: Equatable, Sendable {
        let total: Int
        let successes: Int

        var rate: Double {
            total > 0 ? Double(successes) / Double(total) : 0
        }
    }

    static func logURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(
                "Library/Application Support/Bantay-TUI/focus-log.jsonl")
    }

    /// Append on a serial utility queue so a click never waits on disk.
    static func record(_ event: FocusEvent, home: String = NSHomeDirectory()) {
        queue.async {
            let url = logURL(home: home)
            let manager = FileManager.default
            try? manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var data = try? encoder.encode(event) else { return }
            data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {}
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    static func load(home: String = NSHomeDirectory()) -> [FocusEvent] {
        guard let data = try? Data(contentsOf: logURL(home: home)) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(FocusEvent.self, from: Data($0))
        }
    }

    static func summary(
        _ events: [FocusEvent], since: Date? = nil
    ) -> Summary {
        let filtered: [FocusEvent]
        if let since {
            filtered = events.filter { $0.timestamp >= since }
        } else {
            filtered = events
        }
        return Summary(
            total: filtered.count,
            successes: filtered.filter(\.success).count)
    }

    /// Wait for queued appends. Tests and one-shot reports use this.
    static func flush() {
        queue.sync {}
    }

    private static let queue = DispatchQueue(
        label: "com.bantay.focus-log", qos: .utility)
}
