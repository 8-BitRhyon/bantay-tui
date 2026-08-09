import Foundation

/// Available mascot archetypes for the Notch Pet Companion.
public enum MascotArchetype: String, CaseIterable, Identifiable, Codable {
    case bantayDog = "bantayDog"
    case aiCeo = "aiCeo"
    case cyberCat = "cyberCat"
    case roboBuddy = "roboBuddy"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bantayDog: return "Bantay Guard Dog"
        case .aiCeo: return "The AI CEO (Dario)"
        case .cyberCat: return "Pixel Cyber Cat"
        case .roboBuddy: return "Glow Bot"
        }
    }

    public var iconName: String {
        switch self {
        case .bantayDog: return "dog.fill"
        case .aiCeo: return "briefcase.fill"
        case .cyberCat: return "cat.fill"
        case .roboBuddy: return "cpu.fill"
        }
    }

    public var description: String {
        switch self {
        case .bantayDog: return "Faithful guardian watching over your background terminal jobs."
        case .aiCeo: return "Executive companion keeping tabs on token budgets and agent output."
        case .cyberCat: return "Sleek retro 8-bit cat keeping you company while coding."
        case .roboBuddy: return "Futuristic cyberpunk floating sphere with neon status rings."
        }
    }
}

/// Dynamic reactive states for the mascot.
public enum MascotState: String, CaseIterable, Identifiable {
    case idle = "idle"
    case working = "working"
    case needsAttention = "needsAttention"
    case completed = "completed"
    case quotaLow = "quotaLow"

    public var id: String { rawValue }

    public var statusText: String {
        switch self {
        case .idle: return "Sleeping"
        case .working: return "Coding"
        case .needsAttention: return "Needs You!"
        case .completed: return "Done!"
        case .quotaLow: return "Low Quota"
        }
    }
}

public enum MascotEvaluator {
    /// Evaluates the current mascot state from active agents and quota status.
    static func evaluate(
        agents: [AgentSnapshot],
        quotaLow: Bool = false,
        recentCompletion: Bool = false
    ) -> MascotState {
        let hasAttentionNeeded = agents.contains {
            $0.kind == .accessRequest || $0.kind == .waiting || $0.kind == .failed
        }
        if hasAttentionNeeded {
            return .needsAttention
        }

        let isWorking = agents.contains { $0.kind.isOngoing }
        if isWorking {
            return .working
        }

        if recentCompletion {
            return .completed
        }

        if quotaLow {
            return .quotaLow
        }

        return .idle
    }
}
