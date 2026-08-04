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
    var hideAtStartup = false {
        didSet { defaults.set(hideAtStartup, forKey: "hideAtStartup") }
    }
    var islandDockSide: IslandMetrics.IslandDockSide = .right {
        didSet { defaults.set(islandDockSide.rawValue, forKey: "islandDockSide") }
    }
    var idleStyle: IslandMetrics.IdleStyle = .names {
        didSet { defaults.set(idleStyle.rawValue, forKey: "idleStyle") }
    }
    var idleMaxChips: Int = IslandMetrics.idleDefaultMaxChips {
        didSet { defaults.set(idleMaxChips, forKey: "idleMaxChips") }
    }
    var clampedIdleMaxChips: Int {
        min(max(idleMaxChips, 1), 6)
    }
    var expandedQueueCap: Int = IslandMetrics.expandedQueueCap {
        didSet { defaults.set(expandedQueueCap, forKey: "expandedQueueCap") }
    }
    var clampedExpandedQueueCap: Int {
        min(max(expandedQueueCap, 1), 5)
    }
    var expandedShowQueue = true {
        didSet { defaults.set(expandedShowQueue, forKey: "expandedShowQueue") }
    }
    var expandedGroupByState = true {
        didSet { defaults.set(expandedGroupByState, forKey: "expandedGroupByState") }
    }
    var globalHotkeyEnabled = true {
        didSet { defaults.set(globalHotkeyEnabled, forKey: "globalHotkeyEnabled") }
    }
    var keyboardShortcuts = true {
        didSet { defaults.set(keyboardShortcuts, forKey: "keyboardShortcuts") }
    }
    var edgeGlowEnabled = true {
        didSet { defaults.set(edgeGlowEnabled, forKey: "edgeGlowEnabled") }
    }
    var showElapsedTime = true {
        didSet { defaults.set(showElapsedTime, forKey: "showElapsedTime") }
    }
    var menuBarBadge = true {
        didSet { defaults.set(menuBarBadge, forKey: "menuBarBadge") }
    }
    var snoozeUntilRestart = false {
        didSet { defaults.set(snoozeUntilRestart, forKey: "snoozeUntilRestart") }
    }
    var standaloneScanEnabled = true {
        didSet { defaults.set(standaloneScanEnabled, forKey: "standaloneScanEnabled") }
    }
    var showUsageGauge = true {
        didSet { defaults.set(showUsageGauge, forKey: "showUsageGauge") }
    }
    var usageBudgetUSD: Double = 10.0 {
        didSet {
            usageBudgetUSD = min(max(usageBudgetUSD, 1), 100)
            defaults.set(usageBudgetUSD, forKey: "usageBudgetUSD")
        }
    }
    var ingestEnabled = false {
        didSet { defaults.set(ingestEnabled, forKey: "ingestEnabled") }
    }
    var ingestPort: Int = 41817 {
        didSet {
            ingestPort = Int(IngestHTTP.clampedPort(ingestPort))
            defaults.set(ingestPort, forKey: "ingestPort")
        }
    }
    var showShelfTab = true {
        didSet { defaults.set(showShelfTab, forKey: "showShelfTab") }
    }
    var shelfLimit: Int = 20 {
        didSet {
            shelfLimit = min(max(shelfLimit, 1), 50)
            defaults.set(shelfLimit, forKey: "shelfLimit")
        }
    }
    var clampedShelfLimit: Int {
        min(max(shelfLimit, 1), 50)
    }
    var followMouseScreen = true {
        didSet { defaults.set(followMouseScreen, forKey: "followMouseScreen") }
    }
    var floatingPillOnNoNotch = true {
        didSet { defaults.set(floatingPillOnNoNotch, forKey: "floatingPillOnNoNotch") }
    }
    var showInFullScreen = true {
        didSet { defaults.set(showInFullScreen, forKey: "showInFullScreen") }
    }
    var avoidMenuBarIcons = true {
        didSet { defaults.set(avoidMenuBarIcons, forKey: "avoidMenuBarIcons") }
    }
    var preferredTerminalBundleID: String? {
        didSet { defaults.set(preferredTerminalBundleID, forKey: "preferredTerminalBundleID") }
    }
    var automaticallyChecksForUpdates = false {
        didSet {
            defaults.set(automaticallyChecksForUpdates, forKey: "automaticallyChecksForUpdates")
        }
    }
    var automaticallyDownloadsUpdates = false {
        didSet {
            defaults.set(automaticallyDownloadsUpdates, forKey: "automaticallyDownloadsUpdates")
        }
    }

    var isSnoozed: Bool {
        if snoozeUntilRestart { return true }
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
        if let v = defaults.object(forKey: "hideAtStartup") as? Bool {
            hideAtStartup = v
        }
        if let v = defaults.string(forKey: "islandDockSide"),
            let side = IslandMetrics.IslandDockSide(rawValue: v)
        {
            islandDockSide = side
        }
        if let v = defaults.string(forKey: "idleStyle"),
            let style = IslandMetrics.IdleStyle(rawValue: v)
        {
            idleStyle = style
        }
        if let v = defaults.object(forKey: "idleMaxChips") as? NSNumber {
            idleMaxChips = min(max(v.intValue, 1), 6)
        }
        if let v = defaults.object(forKey: "expandedQueueCap") as? NSNumber {
            expandedQueueCap = min(max(v.intValue, 1), 5)
        }
        if let v = defaults.object(forKey: "expandedShowQueue") as? Bool {
            expandedShowQueue = v
        }
        if let v = defaults.object(forKey: "expandedGroupByState") as? Bool {
            expandedGroupByState = v
        }
        if let v = defaults.object(forKey: "globalHotkeyEnabled") as? Bool {
            globalHotkeyEnabled = v
        }
        if let v = defaults.object(forKey: "keyboardShortcuts") as? Bool {
            keyboardShortcuts = v
        }
        if let v = defaults.object(forKey: "edgeGlowEnabled") as? Bool {
            edgeGlowEnabled = v
        }
        if let v = defaults.object(forKey: "showElapsedTime") as? Bool {
            showElapsedTime = v
        }
        if let v = defaults.object(forKey: "menuBarBadge") as? Bool {
            menuBarBadge = v
        }
        if let v = defaults.object(forKey: "snoozeUntilRestart") as? Bool {
            snoozeUntilRestart = v
        }
        if let v = defaults.object(forKey: "standaloneScanEnabled") as? Bool {
            standaloneScanEnabled = v
        }
        if let v = defaults.object(forKey: "showUsageGauge") as? Bool {
            showUsageGauge = v
        }
        if let v = defaults.object(forKey: "usageBudgetUSD") as? NSNumber {
            usageBudgetUSD = min(max(v.doubleValue, 1), 100)
        }
        if let v = defaults.object(forKey: "ingestEnabled") as? Bool {
            ingestEnabled = v
        }
        if let v = defaults.object(forKey: "ingestPort") as? NSNumber {
            ingestPort = Int(IngestHTTP.clampedPort(v.intValue))
        }
        if let v = defaults.object(forKey: "showShelfTab") as? Bool {
            showShelfTab = v
        }
        if let v = defaults.object(forKey: "shelfLimit") as? NSNumber {
            shelfLimit = min(max(v.intValue, 1), 50)
        }
        if let v = defaults.object(forKey: "followMouseScreen") as? Bool {
            followMouseScreen = v
        }
        if let v = defaults.object(forKey: "floatingPillOnNoNotch") as? Bool {
            floatingPillOnNoNotch = v
        }
        if let v = defaults.object(forKey: "showInFullScreen") as? Bool {
            showInFullScreen = v
        }
        if let v = defaults.object(forKey: "avoidMenuBarIcons") as? Bool {
            avoidMenuBarIcons = v
        }
        if let v = defaults.string(forKey: "preferredTerminalBundleID") {
            preferredTerminalBundleID = v
        }
        if let v = defaults.object(forKey: "automaticallyChecksForUpdates") as? Bool {
            automaticallyChecksForUpdates = v
        }
        if let v = defaults.object(forKey: "automaticallyDownloadsUpdates") as? Bool {
            automaticallyDownloadsUpdates = v
        }
    }
}
