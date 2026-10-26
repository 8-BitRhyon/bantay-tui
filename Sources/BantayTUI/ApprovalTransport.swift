import CryptoKit
import Foundation

/// Why a decision could not be handed to an agent. These reasons are shown
/// verbatim in the card so a failure is never mistaken for a delivered click.
enum ApprovalFailure: String, Equatable, Sendable {
    case deadPane
    case accessibility
    case inputSynthesisDisabled
    case targetUnavailable
    case emptyText
    case unsupported
    case adapterUnavailable
    case transport

    var message: String {
        switch self {
        case .deadPane:
            return "That pane is gone. Open the agent's terminal."
        case .accessibility:
            return "Accessibility is not granted. Grant it in Settings."
        case .inputSynthesisDisabled:
            return "Input synthesis is unavailable. Open the agent's terminal."
        case .targetUnavailable:
            return "The target app is not running."
        case .emptyText:
            return "Type an answer first."
        case .unsupported:
            return "This agent cannot receive a decision from Bantay yet. Open its terminal."
        case .adapterUnavailable:
            return "The terminal transport is not available."
        case .transport:
            return "The input could not be written to the agent."
        }
    }

    var needsAccessibility: Bool { self == .accessibility }
}

/// The only two outcomes Bantay can prove today. `.sent` means the transport
/// accepted the write. It does not mean the agent accepted the decision;
/// that requires a protocol-level acknowledgment Bantay does not have yet.
enum ApprovalOutcome: Equatable, Sendable {
    case sent
    case failed(ApprovalFailure)

    var isSent: Bool { self == .sent }
}

/// Why an approval surface is review-only. These are not failures: they are
/// permanent (or user-controlled) transport limits, so the UI should not offer
/// an action that can never work.
enum ApprovalObserveReason: String, Equatable, Sendable {
    case externalEvent
    case inputSynthesisDisabled
    case paneUnavailable

    var message: String {
        switch self {
        case .externalEvent:
            return "This agent reports events only. Open its terminal to decide."
        case .inputSynthesisDisabled:
            return "Input synthesis is unavailable. Open the agent's terminal to decide."
        case .paneUnavailable:
            return "That pane is gone. Open the agent's terminal."
        }
    }

    var failure: ApprovalFailure {
        switch self {
        case .externalEvent: return .unsupported
        case .inputSynthesisDisabled: return .inputSynthesisDisabled
        case .paneUnavailable: return .deadPane
        }
    }
}

/// How a pane can receive a decision. OpenCode uses a decision file, standalone
/// agents use synthesized input, and multiplexer panes use their adapter.
enum ApprovalRoute: Equatable, Sendable {
    case openCodeDecisionFile
    case standalone
    case multiplexer(PlexerKind)
    case observeOnly(ApprovalObserveReason)

    var canRespond: Bool {
        if case .observeOnly = self { return false }
        return true
    }

    var label: String {
        switch self {
        case .openCodeDecisionFile: return "opencode_decision_file"
        case .standalone: return "standalone_input"
        case .multiplexer(let kind): return "\(kind.rawValue)_send_keys"
        case .observeOnly: return "observe_only"
        }
    }
}

/// Pure capability rules. The UI uses `supportsDecision` without requiring a
/// live roster row, so a new event never flashes Approve before the pane is
/// known. The action path uses `route` and checks liveness before sending.
enum ApprovalRouting {
    static func supportsDecision(
        paneId: String, inputSynthesisEnabled: Bool
    ) -> Bool {
        let trimmed = paneId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isExternalEvent(trimmed) { return false }
        if trimmed.hasPrefix("standalone:") { return inputSynthesisEnabled }
        return true
    }

    static func route(
        paneId: String,
        adapterKind: PlexerKind,
        inputSynthesisEnabled: Bool,
        paneAlive: Bool
    ) -> ApprovalRoute {
        let trimmed = paneId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .observeOnly(.paneUnavailable) }
        if isExternalEvent(trimmed) { return .observeOnly(.externalEvent) }
        if trimmed.hasPrefix("standalone:") {
            return inputSynthesisEnabled
                ? .standalone : .observeOnly(.inputSynthesisDisabled)
        }
        guard paneAlive else { return .observeOnly(.paneUnavailable) }
        if OpenCodeActionWriter.isOpenCodePane(trimmed) {
            return .openCodeDecisionFile
        }
        return .multiplexer(adapterKind)
    }

    private static func isExternalEvent(_ paneId: String) -> Bool {
        paneId.hasPrefix("mcp:") || paneId.hasPrefix("app:")
    }
}

/// Append-only local decision receipt. The request text is hashed, not stored,
/// because prompts can contain commands, paths, and secrets. `agentAck` is
/// explicitly `not_available` until a protocol-level acknowledgment exists.
struct ApprovalReceipt: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let paneId: String
    let source: String?
    let eventKind: String
    let action: String
    let choice: Int?
    let selections: [Int]?
    let requestHash: String
    let idempotencyKey: String
    let route: String
    let outcome: String
    let failure: String?
    let agentAck: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        paneId: String,
        source: String?,
        eventKind: String,
        action: String,
        choice: Int? = nil,
        selections: [Int]? = nil,
        requestHash: String,
        idempotencyKey: String,
        route: String,
        outcome: String,
        failure: String? = nil,
        agentAck: String = "not_available"
    ) {
        self.id = id
        self.createdAt = createdAt
        self.paneId = paneId
        self.source = source
        self.eventKind = eventKind
        self.action = action
        self.choice = choice
        self.selections = selections
        self.requestHash = requestHash
        self.idempotencyKey = idempotencyKey
        self.route = route
        self.outcome = outcome
        self.failure = failure
        self.agentAck = agentAck
    }
}

/// Serialized JSONL receipt log. Writes are rare (one per decision), so a
/// short synchronous queue keeps ordering deterministic without touching the
/// main actor's render path.
final class ApprovalReceiptStore: @unchecked Sendable {
    static let shared = ApprovalReceiptStore()

    let fileURL: URL
    private let queue = DispatchQueue(label: "bantay.approval-receipts")

    init(fileURL: URL? = nil) {
        self.fileURL =
            fileURL
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bantay-TUI/approval-receipts.jsonl", isDirectory: false)
    }

    func append(_ receipt: ApprovalReceipt) {
        queue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(receipt)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data("\n".utf8))
            } catch {
                NSLog("approval-receipts: append failed: %@", String(describing: error))
            }
        }
    }

    func recent(limit: Int = 50) -> [ApprovalReceipt] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                let text = String(data: data, encoding: .utf8)
            else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let receipts = text.split(whereSeparator: \.isNewline).compactMap {
                line -> ApprovalReceipt? in
                guard let lineData = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(ApprovalReceipt.self, from: lineData)
            }
            return Array(receipts.suffix(max(limit, 1)))
        }
    }

    static func requestHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
