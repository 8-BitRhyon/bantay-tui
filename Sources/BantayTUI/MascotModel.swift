import Foundation

/// Wearable pet accessories unlocked via XP gamification.
public enum MascotAccessory: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case partyHat = "partyHat"
    case cyberVisor = "cyberVisor"
    case wizardCap = "wizardCap"
    case goldenCollar = "goldenCollar"
    case retroGlasses = "retroGlasses"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .partyHat: return "Party Hat 🥳"
        case .cyberVisor: return "Cyber Visor 🕶️"
        case .wizardCap: return "Wizard Cap 🧙‍♂️"
        case .goldenCollar: return "Golden Collar 👑"
        case .retroGlasses: return "Retro Glasses 👓"
        }
    }

    public var requiredLevel: Int {
        switch self {
        case .none: return 1
        case .partyHat: return 2
        case .cyberVisor: return 4
        case .wizardCap: return 6
        case .goldenCollar: return 8
        case .retroGlasses: return 10
        }
    }

    public var iconName: String {
        switch self {
        case .none: return ""
        case .partyHat: return "party.popper.fill"
        case .cyberVisor: return "sunglasses.fill"
        case .wizardCap: return "sparkles"
        case .goldenCollar: return "crown.fill"
        case .retroGlasses: return "eyeglasses"
        }
    }
}

/// Available mascot archetypes for the Notch Pet Companion.
public enum MascotArchetype: String, CaseIterable, Identifiable, Codable {
    case bantayDog = "bantayDog"
    case aiCeo = "aiCeo"
    case cyberCat = "cyberCat"
    case roboBuddy = "roboBuddy"
    case codeWizard = "codeWizard"
    case coffeeDev = "coffeeDev"
    case gitDragon = "gitDragon"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bantayDog: return "Bantay Guard Dog"
        case .aiCeo: return "The AI CEO (Dario)"
        case .cyberCat: return "Pixel Cyber Cat"
        case .roboBuddy: return "Glow Bot"
        case .codeWizard: return "Code Wizard"
        case .coffeeDev: return "Espresso Dev"
        case .gitDragon: return "Repo Sentinel Dragon"
        }
    }

    public var iconName: String {
        switch self {
        case .bantayDog: return "dog.fill"
        case .aiCeo: return "briefcase.fill"
        case .cyberCat: return "cat.fill"
        case .roboBuddy: return "cpu.fill"
        case .codeWizard: return "wand.and.stars"
        case .coffeeDev: return "cup.and.saucer.fill"
        case .gitDragon: return "lizard.fill"
        }
    }

    public var description: String {
        switch self {
        case .bantayDog:
            return "Faithful guardian watching over your background terminal jobs."
        case .aiCeo:
            return "Executive companion keeping tabs on token budgets and agent output."
        case .cyberCat:
            return "Sleek retro 8-bit cat keeping you company while coding."
        case .roboBuddy:
            return "Futuristic cyberpunk floating sphere with neon status rings."
        case .codeWizard:
            return "Mystical sorcerer casting background compilation spells."
        case .coffeeDev:
            return "Cozy caffeine-driven companion keeping spirits high."
        case .gitDragon:
            return "Ancient dragon guarding your git repository and commits."
        }
    }

    /// Reactive personality quote for thought bubbles.
    public func personalityQuote(for state: MascotState) -> String {
        switch (self, state) {
        case (.bantayDog, .idle): return "Sleeping on guard duty... Zzz"
        case (.bantayDog, .working): return "Ears up! Watching agents code..."
        case (.bantayDog, .needsAttention): return "Woof! An agent needs your sign-off!"
        case (.bantayDog, .completed): return "Good job! Build passed clean!"
        case (.bantayDog, .quotaLow): return "Low quota! Barking at API limit..."

        case (.aiCeo, .idle): return "Reviewing quarterly token ROI..."
        case (.aiCeo, .working): return "Optimizing background throughput..."
        case (.aiCeo, .needsAttention): return "Executive decision required ASAP!"
        case (.aiCeo, .completed): return "Target shipped under budget!"
        case (.aiCeo, .quotaLow): return "Whoa! Token burn rate high!"

        case (.cyberCat, .idle): return "Napping near warm CPU exhaust..."
        case (.cyberCat, .working): return "Purring at 60fps AST refactors..."
        case (.cyberCat, .needsAttention): return "Meow! Terminal needs attention!"
        case (.cyberCat, .completed): return "Paws up! Clean git commit!"
        case (.cyberCat, .quotaLow): return "Low quota kibble..."

        case (.roboBuddy, .idle): return "Standby mode active [0x00]"
        case (.roboBuddy, .working): return "Synthesizing AST nodes..."
        case (.roboBuddy, .needsAttention): return "ALERT: Interrupt signal requested"
        case (.roboBuddy, .completed): return "Process exited with code 0"
        case (.roboBuddy, .quotaLow): return "Battery/Quota at 15%"

        case (.codeWizard, .idle): return "Meditating on ancient algorithms..."
        case (.codeWizard, .working): return "Weaving background thread spells..."
        case (.codeWizard, .needsAttention): return "You shall not pass without bash approval!"
        case (.codeWizard, .completed): return "Spell successful! Tests green!"
        case (.codeWizard, .quotaLow): return "Mana pool running low..."

        case (.coffeeDev, .idle): return "Sipping warm espresso..."
        case (.coffeeDev, .working): return "Steaming through unit tests..."
        case (.coffeeDev, .needsAttention): return "Hot spill! Approval needed!"
        case (.coffeeDev, .completed): return "Extra shot of victory!"
        case (.coffeeDev, .quotaLow): return "Running on empty..."

        case (.gitDragon, .idle): return "Slumbering on top of main branch..."
        case (.gitDragon, .working): return "Breathing cyan flames into build..."
        case (.gitDragon, .needsAttention): return "Halt! Repo boundary challenged!"
        case (.gitDragon, .completed): return "Git commit secured in hoard!"
        case (.gitDragon, .quotaLow): return "Treasure budget running thin..."
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
