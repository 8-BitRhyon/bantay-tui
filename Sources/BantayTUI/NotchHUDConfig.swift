import Foundation

@MainActor
final class NotchHUDConfig {
    static let shared = NotchHUDConfig()

    var stickyApprovalSources: Set<String> = ["codex", "cursor", "freebuff", "commandcode"]
    var enableAgentAlerts = true {
        didSet { defaults.set(enableAgentAlerts, forKey: "enableAgentAlerts") }
    }
    var soundVolume: Float = 0.35 {
        didSet { defaults.set(soundVolume, forKey: "soundVolume") }
    }
    var autoClearTTL: TimeInterval = 3.0 {
        didSet { defaults.set(autoClearTTL, forKey: "autoClearTTL") }
    }
    var stickyApprovalTTL: TimeInterval = 30.0 {
        didSet { defaults.set(stickyApprovalTTL, forKey: "stickyApprovalTTL") }
    }
    var captureEnabled = true {
        didSet { defaults.set(captureEnabled, forKey: "captureEnabled") }
    }
    var captureInterval: TimeInterval = 2.0 {
        didSet { defaults.set(captureInterval, forKey: "captureInterval") }
    }
    var idlePollInterval: TimeInterval = 10.0 {
        didSet { defaults.set(idlePollInterval, forKey: "idlePollInterval") }
    }
    var soundCooldown: TimeInterval = 5.0 {
        didSet { defaults.set(soundCooldown, forKey: "soundCooldown") }
    }
    var muteInTerminal: Bool = true {
        didSet { defaults.set(muteInTerminal, forKey: "muteInTerminal") }
    }
    var islandEnabled = true {
        didSet { defaults.set(islandEnabled, forKey: "islandEnabled") }
    }
    var snoozedUntil: Date? {
        didSet { defaults.set(snoozedUntil, forKey: "snoozedUntil") }
    }

    var isSnoozed: Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil.timeIntervalSinceNow > 0
    }

    private let defaults = UserDefaults.standard

    private init() {
        if let v = defaults.object(forKey: "enableAgentAlerts") as? Bool {
            enableAgentAlerts = v
        }
        if let v = defaults.object(forKey: "soundVolume") as? NSNumber {
            soundVolume = v.floatValue
        }
        if let v = defaults.object(forKey: "autoClearTTL") as? NSNumber {
            autoClearTTL = v.doubleValue
        }
        if let v = defaults.object(forKey: "stickyApprovalTTL") as? NSNumber {
            stickyApprovalTTL = v.doubleValue
        }
        if let v = defaults.object(forKey: "captureEnabled") as? Bool {
            captureEnabled = v
        }
        if let v = defaults.object(forKey: "captureInterval") as? NSNumber {
            captureInterval = v.doubleValue
        }
        if let v = defaults.object(forKey: "idlePollInterval") as? NSNumber {
            idlePollInterval = v.doubleValue
        }
        if let v = defaults.object(forKey: "soundCooldown") as? NSNumber {
            soundCooldown = v.doubleValue
        }
        if let v = defaults.object(forKey: "muteInTerminal") as? NSNumber {
            muteInTerminal = v.boolValue
        }
        if let v = defaults.object(forKey: "islandEnabled") as? Bool {
            islandEnabled = v
        }
        if let v = defaults.object(forKey: "snoozedUntil") as? Date {
            snoozedUntil = v
        }
    }
}
