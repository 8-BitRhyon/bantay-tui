import Foundation

/// Deep-link destination inside the single Settings modal. The modal window
/// stays shared; routes only select a category and an optional section.
enum SettingsRoute: String, CaseIterable, Identifiable, Sendable {
    case general
    case agents
    case approvals
    case notch
    case desktop
    case notifications
    case integrations
    case advanced

    var id: String { rawValue }

    /// Current SettingsView category name. Renamed in Phase 4: Appearance
    /// became Notch, Infinite Strip became Desktop.
    var categoryName: String {
        switch self {
        case .general: return "General"
        case .agents, .approvals: return "Agents"
        case .notch: return "Notch"
        case .desktop: return "Desktop"
        case .notifications: return "Notifications"
        case .integrations: return "Integrations"
        case .advanced: return "Advanced"
        }
    }

    /// SettingsView section title to land on. Used as the settings search
    /// filter so the deep link shows the matching section.
    var sectionTitle: String? {
        switch self {
        case .general: return "Quick actions"
        case .agents: return "Tasks & Dispatching"
        case .approvals: return "Approval safety"
        case .notch: return "Expanded panel"
        case .desktop: return "Desktop HUD"
        case .notifications: return "Alerts"
        case .integrations: return "Claude Code hook"
        case .advanced: return "Capture"
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .general: return ["startup", "shortcuts", "displays"]
        case .agents: return ["agents", "tasks", "dispatch", "muted sources"]
        case .approvals: return ["approval", "approve", "deny", "risk", "policy"]
        case .notch: return ["notch", "panel", "tabs", "idle", "mascot"]
        case .desktop: return ["desktop", "strip", "chain", "columns", "halos"]
        case .notifications: return ["alerts", "sounds", "quiet hours", "push"]
        case .integrations: return ["claude", "opencode", "herdr", "ssh"]
        case .advanced: return ["capture", "permissions", "accessibility", "reset"]
        }
    }

    /// CLI and socket argument parsing: `bantay settings desktop`.
    static func resolve(cliArgument: String) -> SettingsRoute? {
        switch cliArgument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "general": return .general
        case "agents": return .agents
        case "approvals", "approval": return .approvals
        case "notch", "appearance": return .notch
        case "desktop", "strip": return .desktop
        case "notifications", "alerts": return .notifications
        case "integrations": return .integrations
        case "advanced", "permissions": return .advanced
        default: return nil
        }
    }
}
