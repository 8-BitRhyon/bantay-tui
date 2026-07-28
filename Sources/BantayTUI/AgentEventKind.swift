import Foundation

enum AgentEventKind: String, Decodable, CaseIterable {
    case accessRequest = "access_request"
    case clear = "clear"
    case waiting = "waiting"
    case completed = "completed"
    case failed = "failed"
    case started = "started"
    case progress = "progress"
    case cancelled = "cancelled"

    var label: String {
        switch self {
        case .accessRequest: return "Need approval"
        case .clear: return ""
        case .waiting: return "Blocked"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .started: return "Started"
        case .progress: return "Working"
        case .cancelled: return "Cancelled"
        }
    }

    var color: String {
        switch self {
        case .accessRequest: return "#ff6b6b"
        case .clear: return "#8a8aa8"
        case .waiting: return "#ffe066"
        case .completed: return "#4ecdc4"
        case .failed: return "#ff6b6b"
        case .started: return "#8b7eff"
        case .progress: return "#8b7eff"
        case .cancelled: return "#8a8aa8"
        }
    }

    var soundName: String {
        switch self {
        case .accessRequest, .waiting: return "Ping"
        case .completed: return "Glass"
        default: return "Submarine"
        }
    }
}
