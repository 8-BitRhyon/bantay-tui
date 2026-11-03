import Foundation
import SQLite3

private let antigravitySQLiteTransient = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self)

/// Read-only decoder for Antigravity's cached provider quota.
///
/// The IDE stores a base64-wrapped protobuf in `state.vscdb` under
/// `antigravityUnifiedStateSync.userStatus`. The observed wrapper is
/// field 1 -> field 2 -> field 1 -> base64(payload). The payload carries
/// per-model quota in field 33.1.15:
///   1: float remainingFraction (0...1)
///   2: timestamp message, field 1: int64 epoch seconds
/// Field 36 carries the plan tier. Credit counts also exist in the blob,
/// but their field mapping is not proven, so this decoder ignores them.
/// Only quota numbers, model names, and the tier leave this file. No
/// account email, token, or raw blob is logged or returned.
enum AntigravityQuota {
    struct State: Equatable, Sendable {
        let remainingPercent: Double
        let resetsAt: Date?
        let tier: String
        let modelName: String?
        let modelCount: Int
        let isStale: Bool
    }

    static let userStatusKey = "antigravityUnifiedStateSync.userStatus"
    static let databaseRelativePath =
        "Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb"

    static func databaseURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(databaseRelativePath)
    }

    /// Provider row for the notch, or nil when the cache is absent,
    /// corrupt, or carries no decodable quota.
    static func quota(home: String = NSHomeDirectory(), now: Date = Date())
        -> ProviderQuota?
    {
        guard let state = state(home: home, now: now) else { return nil }
        return ProviderQuota(
            provider: "Antigravity",
            remainingPercent: state.remainingPercent,
            resetHint: state.isStale ? "Stale · window ended" : "No reset reported",
            tier: state.tier,
            totalDisplay: state.modelCount > 1 ? "\(state.modelCount) models" : "",
            resetsAt: state.isStale ? nil : state.resetsAt,
            hidesProgress: false,
            rowLabel: "Reported",
            isStale: state.isStale)
    }

    static func state(home: String = NSHomeDirectory(), now: Date = Date()) -> State? {
        guard let data = readUserStatus(home: home) else { return nil }
        return parseUserStatus(data, now: now)
    }

    /// Reads the cached value. Opens read-only without `immutable=1` so
    /// SQLite sees the WAL. A locked or missing cache reads as no data.
    static func readUserStatus(home: String = NSHomeDirectory()) -> Data? {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var handle: OpaquePointer?
        let uri = "file://\(url.path)?mode=ro"
        guard
            sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
                == SQLITE_OK,
            let handle
        else {
            if handle != nil { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 500)

        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                handle,
                "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
                -1, &stmt, nil) == SQLITE_OK,
            let stmt
        else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, userStatusKey, -1, antigravitySQLiteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard count > 0, let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: blob, count: count)
    }

    /// Parses the SQLite value: an outer base64 string, the wrapper hops,
    /// then the payload protobuf. Unknown wrapper fields are tolerated
    /// because only the first nested message is followed.
    static func parseUserStatus(_ data: Data, now: Date = Date()) -> State? {
        guard var current = decodeBase64(data) else { return nil }
        for _ in 0..<6 {
            if let fields = Proto.fields(current),
                fields.contains(where: { $0.number == 33 || $0.number == 36 })
            {
                return parsePayload(current, now: now)
            }
            // Some versions store the payload directly as a base64 string.
            if let decoded = decodeBase64(current),
                let fields = Proto.fields(decoded),
                fields.contains(where: { $0.number == 33 || $0.number == 36 })
            {
                return parsePayload(decoded, now: now)
            }
            // The wrapper is a key-value row: a short sentinel key plus a
            // much larger value. Follow the largest nested field so the
            // key string is never mistaken for the payload.
            guard let nested = Proto.largestBytes(in: current) else { return nil }
            current = nested
        }
        return parsePayload(current, now: now)
    }

    static func parsePayload(_ payload: Data, now: Date = Date()) -> State? {
        guard let fields = Proto.fields(payload) else { return nil }
        let tier = tierName(from: fields) ?? "Antigravity"
        guard
            let container = Proto.firstBytes(field: 33, in: payload),
            let containerFields = Proto.fields(container)
        else { return nil }

        var bestFraction: Double?
        var bestReset: Date?
        var bestName: String?
        var modelCount = 0
        for entry in containerFields where entry.number == 1 && entry.wire == 2 {
            guard let entryBytes = entry.bytes,
                let entryFields = Proto.fields(entryBytes),
                let quotaBytes = Proto.firstBytes(field: 15, in: entryBytes),
                let quotaFields = Proto.fields(quotaBytes),
                let fractionField = quotaFields.first(where: {
                    $0.number == 1 && $0.wire == 5
                }),
                let bits = fractionField.fixed32
            else { continue }
            let fraction = Double(Float(bitPattern: bits))
            guard fraction.isFinite, (0.0...1.0).contains(fraction) else { continue }
            modelCount += 1
            let reset = resetDate(from: quotaFields)
            let name: String? = {
                guard let bytes = Proto.firstBytes(field: 1, in: entryFields) else {
                    return nil
                }
                return String(data: bytes, encoding: .utf8)
            }()
            if let currentBest = bestFraction {
                if fraction < currentBest
                    || (fraction == currentBest && earlier(reset, bestReset))
                {
                    bestFraction = fraction
                    bestReset = reset
                    bestName = name
                }
            } else {
                bestFraction = fraction
                bestReset = reset
                bestName = name
            }
        }
        guard let bestFraction else { return nil }
        let stale = bestReset.map { $0 <= now } ?? false
        return State(
            remainingPercent: min(max(bestFraction * 100.0, 0.0), 100.0),
            resetsAt: bestReset,
            tier: tier,
            modelName: bestName,
            modelCount: modelCount,
            isStale: stale)
    }

    private static func resetDate(from fields: [Proto.Field]) -> Date? {
        guard
            let resetBytes = Proto.firstBytes(field: 2, in: fields),
            let resetFields = Proto.fields(resetBytes),
            let secondsField = resetFields.first(where: {
                $0.number == 1 && $0.wire == 0
            }),
            let seconds = secondsField.varint,
            (1_500_000_000...2_500_000_000).contains(seconds)
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func earlier(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (let left?, let right?): return left < right
        case (_?, nil): return true
        default: return false
        }
    }

    private static func tierName(from fields: [Proto.Field]) -> String? {
        guard
            let tierBytes = Proto.firstBytes(field: 36, in: fields),
            let tierFields = Proto.fields(tierBytes)
        else { return nil }
        for number in [2, 3] {
            guard let bytes = Proto.firstBytes(field: number, in: tierFields),
                let raw = String(data: bytes, encoding: .utf8)
            else { continue }
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, cleaned.count <= 32,
                !cleaned.unicodeScalars.contains(where: {
                    $0.properties.generalCategory == .control
                })
            {
                return cleaned
            }
        }
        return nil
    }

    private static func decodeBase64(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count % 4 == 0 else { return nil }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return Data(base64Encoded: trimmed)
    }

    /// Minimal protobuf wire reader. Groups are rejected rather than
    /// guessed, and field counts are capped so a corrupt blob cannot make
    /// the 60s poll spin.
    enum Proto {
        struct Field {
            let number: Int
            let wire: Int
            let varint: UInt64?
            let bytes: Data?
            let fixed32: UInt32?
        }

        static func fields(_ data: Data) -> [Field]? {
            let bytes = [UInt8](data)
            var index = 0
            var out: [Field] = []
            while index < bytes.count {
                guard let key = readVarint(bytes, &index), key > 0 else { return nil }
                let number = Int(key >> 3)
                let wire = Int(key & 0x07)
                guard number > 0, number <= 1_000_000 else { return nil }
                switch wire {
                case 0:
                    guard let value = readVarint(bytes, &index) else { return nil }
                    out.append(
                        Field(
                            number: number, wire: wire, varint: value, bytes: nil,
                            fixed32: nil))
                case 1:
                    guard index + 8 <= bytes.count else { return nil }
                    index += 8
                    out.append(
                        Field(
                            number: number, wire: wire, varint: nil, bytes: nil,
                            fixed32: nil))
                case 2:
                    guard let length = readVarint(bytes, &index),
                        length <= UInt64(bytes.count - index)
                    else { return nil }
                    let end = index + Int(length)
                    out.append(
                        Field(
                            number: number, wire: wire, varint: nil,
                            bytes: Data(bytes[index..<end]), fixed32: nil))
                    index = end
                case 5:
                    guard index + 4 <= bytes.count else { return nil }
                    let value =
                        UInt32(bytes[index])
                        | (UInt32(bytes[index + 1]) << 8)
                        | (UInt32(bytes[index + 2]) << 16)
                        | (UInt32(bytes[index + 3]) << 24)
                    index += 4
                    out.append(
                        Field(
                            number: number, wire: wire, varint: nil, bytes: nil,
                            fixed32: value))
                default:
                    return nil
                }
                if out.count > 5000 { return nil }
            }
            return out
        }

        static func largestBytes(in data: Data) -> Data? {
            guard let fields = fields(data) else { return nil }
            var best: Data?
            for field in fields where field.wire == 2 {
                guard let bytes = field.bytes else { continue }
                if best == nil || bytes.count > (best?.count ?? 0) {
                    best = bytes
                }
            }
            return best
        }

        static func firstBytes(field: Int, in data: Data) -> Data? {
            guard let fields = fields(data) else { return nil }
            return firstBytes(field: field, in: fields)
        }

        static func firstBytes(field: Int, in fields: [Field]) -> Data? {
            fields.first { $0.number == field && $0.wire == 2 }?.bytes
        }

        private static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            var count = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                count += 1
                if count >= 10 { return nil }
            }
            return nil
        }
    }
}
