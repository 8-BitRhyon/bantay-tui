import Foundation
import SQLite3

/// Read-only view over Antigravity's local conversation store
/// (`~/.gemini/antigravity-ide/conversations/<uuid>.db`). Each conversation
/// is a SQLite file whose `steps` table carries a type, a status, and a
/// protobuf metadata blob. The metadata's summary fields (30 and 31 in the
/// observed schema) hold the tool action and its human-readable summary,
/// which is what the notch should show instead of transcript noise.
///
/// Token counts are not decoded: no usage fields were found in the store
/// during the plan 022 spike, and Bantay does not fabricate them. Sessions
/// therefore record steps and duration honestly, with zero tokens.
enum AntigravityStore {
    struct Conversation: Equatable, Sendable {
        let id: String
        let updatedAt: Date
        let stepCount: Int
        let headline: String?
        let isWorking: Bool
    }

    struct Snapshot: Equatable, Sendable {
        let conversations: [Conversation]

        var latest: Conversation? { conversations.first }
        var isWorking: Bool { conversations.contains { $0.isWorking } }
        var totalSteps: Int { conversations.reduce(0) { $0 + $1.stepCount } }
    }

    /// A conversation counts as working while its file changed recently:
    /// the IDE writes steps as the agent acts, so mtime is the heartbeat.
    static let workingWindow: TimeInterval = 120

    static func conversationsDirectory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(".gemini/antigravity-ide/conversations", isDirectory: true)
    }

    static func snapshot(
        home: String = NSHomeDirectory(), now: Date = Date(), limit: Int = 12
    ) -> Snapshot {
        let dir = conversationsDirectory(home: home)
        let files =
            ((try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "db" }
        let sorted = files.sorted { lhs, rhs in
            (modificationDate(of: lhs) ?? .distantPast)
                > (modificationDate(of: rhs) ?? .distantPast)
        }
        let conversations = sorted.prefix(max(limit, 0)).compactMap {
            readConversation(at: $0, now: now)
        }
        return Snapshot(conversations: conversations)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    private static func readConversation(at url: URL, now: Date) -> Conversation? {
        var handle: OpaquePointer?
        let uri = "file://\(url.path)?immutable=1&mode=ro"
        guard
            sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
                == SQLITE_OK, let handle
        else {
            if handle != nil { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(handle) }

        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                handle,
                "SELECT step_type, metadata FROM steps ORDER BY idx DESC LIMIT 12",
                -1, &stmt, nil) == SQLITE_OK, let stmt
        else {
            sqlite3_finalize(stmt)
            return nil
        }
        // The newest step is often a planner turn with no summary. Scan
        // back to the most recent step that carries one.
        var latestType = 0
        var latestHeadline: String?
        var isFirstRow = true
        while sqlite3_step(stmt) == SQLITE_ROW {
            if isFirstRow {
                latestType = Int(sqlite3_column_int(stmt, 0))
                isFirstRow = false
            }
            if latestHeadline == nil, let blob = sqlite3_column_blob(stmt, 1) {
                let count = Int(sqlite3_column_bytes(stmt, 1))
                latestHeadline = headline(fromMetadata: Data(bytes: blob, count: count))
            }
        }
        sqlite3_finalize(stmt)

        var countStmt: OpaquePointer?
        var stepCount = 0
        if sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM steps", -1, &countStmt, nil)
            == SQLITE_OK, let countStmt
        {
            if sqlite3_step(countStmt) == SQLITE_ROW {
                stepCount = Int(sqlite3_column_int(countStmt, 0))
            }
            sqlite3_finalize(countStmt)
        }

        let updatedAt = modificationDate(of: url) ?? .distantPast
        let resolvedHeadline = latestHeadline ?? stepTypeHeadline(latestType)
        return Conversation(
            id: url.deletingPathExtension().lastPathComponent,
            updatedAt: updatedAt,
            stepCount: stepCount,
            headline: resolvedHeadline,
            isWorking: now.timeIntervalSince(updatedAt) < workingWindow
                && now.timeIntervalSince(updatedAt) >= 0)
    }

    /// Human headline from a step metadata blob. Field 31 carries the
    /// gerund summary ("Listing files"), field 30 the imperative action
    /// ("List files"); prefer the summary. Anything that cleans to garbage
    /// is suppressed, never rendered raw.
    static func headline(fromMetadata data: Data) -> String? {
        let strings = protoStrings(data)
        for field in [31, 30] {
            guard let raw = strings[field] else { continue }
            let cleaned = IslandMetrics.cleanHUDText(raw, maxCharacters: 60)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    /// Fallback headline by observed step type when a step has no summary.
    static func stepTypeHeadline(_ stepType: Int) -> String {
        switch stepType {
        case 15: return "Thinking"
        case 21: return "Running tool"
        default: return "Working"
        }
    }

    /// Top-level length-delimited protobuf fields as strings, keyed by
    /// field number. Non-printable payloads are skipped.
    static func protoStrings(_ data: Data) -> [Int: String] {
        let bytes = [UInt8](data)
        var result: [Int: String] = [:]
        var index = 0

        func readVarint() -> Int? {
            var value = 0
            var shift = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                value |= Int(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        while index < bytes.count {
            guard let key = readVarint() else { break }
            let field = key >> 3
            let wire = key & 7
            guard field > 0 else { break }
            switch wire {
            case 0:
                guard readVarint() != nil else { return result }
            case 2:
                guard let length = readVarint(), length >= 0,
                    index + length <= bytes.count
                else { return result }
                let chunk = Data(bytes[index..<(index + length)])
                index += length
                if let text = String(data: chunk, encoding: .utf8),
                    !text.isEmpty,
                    text.allSatisfy({
                        !$0.unicodeScalars.contains(where: {
                            $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t"
                        })
                    })
                {
                    result[field] = text
                }
            case 1:
                index += 8
            case 5:
                index += 4
            default:
                return result
            }
            if index > bytes.count { break }
        }
        return result
    }
}
