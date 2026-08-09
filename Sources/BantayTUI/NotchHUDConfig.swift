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
    var soundCooldown: TimeInterval = 5.0 {
        didSet { defaults.set(soundCooldown, forKey: "soundCooldown") }
    }
    var muteInTerminal: Bool = true {
        didSet { defaults.set(muteInTerminal, forKey: "muteInTerminal") }
    }
    /// Post a Notification Center alert when an approval arrives while the
    /// island is hidden (snoozed / hide-at-startup). Opt-in; default off.
    var notifyWhenHidden = false {
        didSet { defaults.set(notifyWhenHidden, forKey: "notifyWhenHidden") }
    }
    /// ntfy.sh push notification topic (e.g. "bantay-agent-alerts"). When set
    /// and non-empty, blocked/approval events are pushed to the topic so they
    /// reach you on other devices. Works with any ntfy server; override the
    /// base URL for self-hosted instances.
    var ntfyTopic: String = "" {
        didSet { defaults.set(ntfyTopic, forKey: "ntfyTopic") }
    }
    var ntfyServer: String = "https://ntfy.sh" {
        didSet { defaults.set(ntfyServer, forKey: "ntfyServer") }
    }
    /// The ntfy push is only enabled when a topic is configured.
    var ntfyEnabled: Bool { !ntfyTopic.isEmpty }
    /// Gate for the transcript token/cost enumeration. Enabled by default
    /// for live spend guardrails & edge-glow alerts.
    var usageTrackingEnabled = true {
        didSet { defaults.set(usageTrackingEnabled, forKey: "usageTrackingEnabled") }
    }
    /// Daily spend budget in USD (default $10.00). Triggers peripheral amber glow at
    /// 70% and pulsing crimson alert glow at 100%.
    var dailyBudgetUSD: Double = 10.0 {
        didSet {
            dailyBudgetUSD = min(max(dailyBudgetUSD, 1), 100)
            defaults.set(dailyBudgetUSD, forKey: "dailyBudgetUSD")
        }
    }
    /// Ambient notch edge-glow indicating live spend level (cyan/amber/red).
    var enableSpendGlow: Bool = true {
        didSet { defaults.set(enableSpendGlow, forKey: "enableSpendGlow") }
    }
    /// Live token throughput rate ticker (⚡ t/min) in expanded island header.
    var showTokenRate: Bool = true {
        didSet { defaults.set(showTokenRate, forKey: "showTokenRate") }
    }
    /// Mascot & Notch Pet Companion toggle. Enabled by default.
    var showNotchMascot: Bool = true {
        didSet { defaults.set(showNotchMascot, forKey: "showNotchMascot") }
    }
    /// Selected mascot archetype (bantayDog, aiCeo, cyberCat, roboBuddy).
    var selectedMascotArchetype: MascotArchetype = .bantayDog {
        didSet { defaults.set(selectedMascotArchetype.rawValue, forKey: "selectedMascotArchetype") }
    }
    /// Shows the Barrie-style Tasks tab in the expanded island.
    var showTasksTab: Bool = true {
        didSet { defaults.set(showTasksTab, forKey: "showTasksTab") }
    }
    /// Enables live quota-axi provider quota gauge in header bar.
    var enableQuotaAxiGauge: Bool = true {
        didSet { defaults.set(enableQuotaAxiGauge, forKey: "enableQuotaAxiGauge") }
    }
    /// Alias for globalHotkeyEnabled for backwards compatibility.
    var enableGlobalHotkey: Bool {
        get { globalHotkeyEnabled }
        set { globalHotkeyEnabled = newValue }
    }
    /// Sound Theme Preset name ("Sleek Modern", "Retro Synth", "Minimalist", "Industrial", "Custom").
    var soundThemePreset: String = "Sleek Modern" {
        didSet {
            defaults.set(soundThemePreset, forKey: "soundThemePreset")
            if soundThemePreset != "Custom" && !isInitializing {
                applySoundThemePreset(soundThemePreset)
            }
        }
    }
    /// Sound effect for approval / access requests.
    var approvalSoundName: String = "Glass" {
        didSet { defaults.set(approvalSoundName, forKey: "approvalSoundName") }
    }
    /// Sound effect for completed tasks.
    var completionSoundName: String = "Hero" {
        didSet { defaults.set(completionSoundName, forKey: "completionSoundName") }
    }
    /// Sound effect for errors / failed tasks.
    var errorSoundName: String = "Basso" {
        didSet { defaults.set(errorSoundName, forKey: "errorSoundName") }
    }
    /// Quiet tick for ongoing work (progress/started) — distinct from the
    /// louder approval sound so routine activity doesn't chime loudly.
    var workingSoundName: String = "Purr" {
        didSet { defaults.set(workingSoundName, forKey: "workingSoundName") }
    }

    /// Sound effect lookup for an agent event kind. Ongoing work gets a
    /// distinct quiet tick (was wrongly playing the louder approval sound).
    func soundName(for kind: AgentEventKind) -> String {
        switch kind {
        case .accessRequest, .waiting:
            return approvalSoundName
        case .completed:
            return completionSoundName
        case .failed:
            return errorSoundName
        case .progress, .started:
            return workingSoundName
        default:
            return workingSoundName
        }
    }

    /// Apply sound presets from a theme name.
    func applySoundThemePreset(_ theme: String) {
        switch theme {
        case "Sleek Modern":
            approvalSoundName = "Glass"
            completionSoundName = "Hero"
            errorSoundName = "Basso"
            workingSoundName = "Purr"
        case "Retro Synth":
            approvalSoundName = "Tink"
            completionSoundName = "Pop"
            errorSoundName = "Morse"
            workingSoundName = "Frog"
        case "Minimalist":
            approvalSoundName = "Ping"
            completionSoundName = "Purr"
            errorSoundName = "Submarine"
            workingSoundName = "Tink"
        case "Industrial":
            approvalSoundName = "Blow"
            completionSoundName = "Funk"
            errorSoundName = "Sosumi"
            workingSoundName = "Bottle"
        default:
            break
        }
    }
    /// Show a live agent-status line in the tmux status bar via
    /// `#(bantay-status)`. Opt-in; installs on the next launch when enabled.
    var tmuxStatusEnabled = false {
        didSet { defaults.set(tmuxStatusEnabled, forKey: "tmuxStatusEnabled") }
    }
    /// Show the F8 "Attention" tab (needs-input + failed triage). Default off.
    var attentionFilterEnabled = false {
        didSet { defaults.set(attentionFilterEnabled, forKey: "attentionFilterEnabled") }
    }
    /// Quiet hours: window (start/end minutes since midnight) during which
    /// alert sounds are silenced. Approvals stay visible — nothing is missed.
    var quietHoursEnabled = false {
        didSet { defaults.set(quietHoursEnabled, forKey: "quietHoursEnabled") }
    }
    var quietHoursStart = 22 * 60 {
        didSet { defaults.set(quietHoursStart, forKey: "quietHoursStart") }
    }
    var quietHoursEnd = 7 * 60 {
        didSet { defaults.set(quietHoursEnd, forKey: "quietHoursEnd") }
    }

    /// Whether the quiet-hours window covers `date` (defaults to now).
    func isInQuietHours(at date: Date = Date()) -> Bool {
        guard quietHoursEnabled else { return false }
        let cal = Calendar.current
        let minutes =
            cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        return IslandMetrics.quietHoursActive(
            nowMinutes: minutes, startMinutes: quietHoursStart, endMinutes: quietHoursEnd)
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
    var showIslandWhenIdle = true {
        didSet { defaults.set(showIslandWhenIdle, forKey: "showIslandWhenIdle") }
    }
    var islandDockSide: IslandMetrics.IslandDockSide = .center {
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
    var globalHotkeyApproveEnabled = true {
        didSet { defaults.set(globalHotkeyApproveEnabled, forKey: "globalHotkeyApproveEnabled") }
    }
    var globalHotkeyDenyEnabled = true {
        didSet { defaults.set(globalHotkeyDenyEnabled, forKey: "globalHotkeyDenyEnabled") }
    }
    var globalHotkeySnoozeEnabled = false {
        didSet { defaults.set(globalHotkeySnoozeEnabled, forKey: "globalHotkeySnoozeEnabled") }
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
    /// Token rate indicator: amber when tokens/min ≥ this, red at ≥ 2×.
    var usageRateWarnTokensPerMin: Int = 5000 {
        didSet {
            usageRateWarnTokensPerMin = min(max(usageRateWarnTokensPerMin, 100), 1_000_000)
            defaults.set(usageRateWarnTokensPerMin, forKey: "usageRateWarnTokensPerMin")
        }
    }
    var ingestEnabled = false {
        didSet { defaults.set(ingestEnabled, forKey: "ingestEnabled") }
    }

    /// Local Unix-domain socket ingest (plan 017 W2). Default ON: a
    /// user-owned socket file (mode 0600) inside the app-support directory
    /// is not a network exposure, unlike the TCP port (`ingestEnabled`),
    /// which stays default-off.
    var ingestSocketEnabled = true {
        didSet { defaults.set(ingestSocketEnabled, forKey: "ingestSocketEnabled") }
    }

    /// Local control gateway (W1 wire contract): a Unix-domain socket owned
    /// by the current user, not a network exposure — so it defaults ON unlike
    /// the TCP ingest port. A stale socket file from a crash is probed and
    /// unlinked on start.
    var gatewayEnabled = true {
        didSet { defaults.set(gatewayEnabled, forKey: "gatewayEnabled") }
    }
    var ingestPort: Int = 41817 {
        didSet {
            ingestPort = Int(IngestHTTP.clampedPort(ingestPort))
            defaults.set(ingestPort, forKey: "ingestPort")
        }
    }
    /// Shared secret required on every ingest request (`/events?token=…`).
    /// Generated once at first run and persisted; the Claude hook and the
    /// remote `ssh -R` hint embed it, so a local process cannot forge events
    /// or keystroke-inject approvals without it.
    var ingestToken: String {
        if let existing = defaults.string(forKey: "ingestToken"), !existing.isEmpty {
            return existing
        }
        let fresh = Self.generateIngestToken()
        defaults.set(fresh, forKey: "ingestToken")
        return fresh
    }

    /// 32 random hex chars (128 bits) — strong enough for a localhost auth
    /// gate; never persisted to logs.
    static func generateIngestToken() -> String {
        (0..<32).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
    }

    /// Constant-time comparison of the presented ingest token.
    nonisolated static func tokenMatches(_ presented: String, expected: String) -> Bool {
        guard presented.utf8.count == expected.utf8.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(presented.utf8, expected.utf8) {
            diff |= a ^ b
        }
        return diff == 0
    }
    var showShelfTab = true {
        didSet { defaults.set(showShelfTab, forKey: "showShelfTab") }
    }
    /// "Keep expanded" intent (F11). Survives user-driven collapse and
    /// relaunch; clears on explicit unpin and on zero agents.
    var panelPinned = false {
        didSet { defaults.set(panelPinned, forKey: "panelPinned") }
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
    /// How long dropped files stay on the shelf before auto-expiring
    /// ("1 Hour", "1 Day", "3 Days", "1 Week", "Forever"). Raw string so the
    /// harness doesn't depend on the enum; `ShelfKeepDuration` maps it.
    var shelfKeepDuration: String = ShelfKeepDuration.oneDay.rawValue {
        didSet { defaults.set(shelfKeepDuration, forKey: "shelfKeepDuration") }
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
    var claudeHookInstalled = false {
        didSet { defaults.set(claudeHookInstalled, forKey: "claudeHookInstalled") }
    }
    /// Agent sources the user muted via row context menus (skipped in roster).
    var mutedSources: Set<String> = [] {
        didSet { defaults.set(Array(mutedSources), forKey: "mutedSources") }
    }

    var isSnoozed: Bool {
        if snoozeUntilRestart { return true }
        guard let snoozedUntil else { return false }
        return snoozedUntil.timeIntervalSinceNow > 0
    }

    private let defaults = UserDefaults.standard

    private var isInitializing = false

    private init() {
        isInitializing = true
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
        if let v = defaults.object(forKey: "soundCooldown") as? NSNumber {
            soundCooldown = v.doubleValue
        }
        if let v = defaults.object(forKey: "muteInTerminal") as? NSNumber {
            muteInTerminal = v.boolValue
        }
        if let v = defaults.object(forKey: "notifyWhenHidden") as? Bool {
            notifyWhenHidden = v
        }
        if let v = defaults.object(forKey: "ntfyTopic") as? String {
            ntfyTopic = v
        }
        if let v = defaults.object(forKey: "ntfyServer") as? String {
            ntfyServer = v
        }
        if let v = defaults.object(forKey: "tmuxStatusEnabled") as? Bool {
            tmuxStatusEnabled = v
        }
        if let v = defaults.object(forKey: "dailyBudgetUSD") as? NSNumber {
            dailyBudgetUSD = v.doubleValue
        }
        if let v = defaults.object(forKey: "enableSpendGlow") as? Bool {
            enableSpendGlow = v
        }
        if let v = defaults.object(forKey: "showTokenRate") as? Bool {
            showTokenRate = v
        }
        if let v = defaults.object(forKey: "showNotchMascot") as? Bool {
            showNotchMascot = v
        }
        if let v = defaults.string(forKey: "selectedMascotArchetype"),
            let archetype = MascotArchetype(rawValue: v)
        {
            selectedMascotArchetype = archetype
        }
        if let v = defaults.object(forKey: "showTasksTab") as? Bool {
            showTasksTab = v
        }
        if let v = defaults.object(forKey: "enableQuotaAxiGauge") as? Bool {
            enableQuotaAxiGauge = v
        }
        if let v = defaults.object(forKey: "globalHotkeyEnabled") as? Bool {
            globalHotkeyEnabled = v
        }
        // Load per-sound overrides BEFORE applying the theme so a persisted
        // custom sound isn't wiped by the preset's didSet on first launch.
        if let v = defaults.string(forKey: "approvalSoundName") {
            approvalSoundName = v
        }
        if let v = defaults.string(forKey: "completionSoundName") {
            completionSoundName = v
        }
        if let v = defaults.string(forKey: "errorSoundName") {
            errorSoundName = v
        }
        if let v = defaults.string(forKey: "workingSoundName") {
            workingSoundName = v
        }
        if let v = defaults.string(forKey: "soundThemePreset") {
            soundThemePreset = v
        }
        if let v = defaults.object(forKey: "attentionFilterEnabled") as? Bool {
            attentionFilterEnabled = v
        }
        if let v = defaults.object(forKey: "quietHoursEnabled") as? Bool {
            quietHoursEnabled = v
        }
        if let v = defaults.object(forKey: "quietHoursStart") as? NSNumber {
            quietHoursStart = min(max(v.intValue, 0), 1439)
        }
        if let v = defaults.object(forKey: "quietHoursEnd") as? NSNumber {
            quietHoursEnd = min(max(v.intValue, 0), 1439)
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
        if let v = defaults.object(forKey: "showIslandWhenIdle") as? Bool {
            showIslandWhenIdle = v
        }
        if let v = defaults.string(forKey: "islandDockSide"),
            let side = IslandMetrics.IslandDockSide(rawValue: v)
        {
            islandDockSide = side
        } else {
            islandDockSide = .center
            defaults.set("center", forKey: "islandDockSide")
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
        if let v = defaults.object(forKey: "globalHotkeyApproveEnabled") as? Bool {
            globalHotkeyApproveEnabled = v
        }
        if let v = defaults.object(forKey: "globalHotkeyDenyEnabled") as? Bool {
            globalHotkeyDenyEnabled = v
        }
        if let v = defaults.object(forKey: "globalHotkeySnoozeEnabled") as? Bool {
            globalHotkeySnoozeEnabled = v
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
        if let v = defaults.object(forKey: "usageRateWarnTokensPerMin") as? NSNumber {
            usageRateWarnTokensPerMin = min(max(v.intValue, 100), 1_000_000)
        }
        if let v = defaults.object(forKey: "ingestEnabled") as? Bool {
            ingestEnabled = v
        }

        if let v = defaults.object(forKey: "ingestSocketEnabled") as? Bool {
            ingestSocketEnabled = v
        }
        if let v = defaults.object(forKey: "gatewayEnabled") as? Bool {
            gatewayEnabled = v
        }
        if let v = defaults.object(forKey: "ingestPort") as? NSNumber {
            ingestPort = Int(IngestHTTP.clampedPort(v.intValue))
        }
        if let v = defaults.object(forKey: "showShelfTab") as? Bool {
            showShelfTab = v
        }
        if let v = defaults.object(forKey: "panelPinned") as? Bool {
            panelPinned = v
        }
        if let v = defaults.object(forKey: "shelfLimit") as? NSNumber {
            shelfLimit = min(max(v.intValue, 1), 50)
        }
        if let v = defaults.object(forKey: "shelfKeepDuration") as? String {
            shelfKeepDuration = v
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
        if let v = defaults.object(forKey: "claudeHookInstalled") as? Bool {
            claudeHookInstalled = v
        }
        if let v = defaults.array(forKey: "mutedSources") as? [String] {
            mutedSources = Set(v)
        }
        isInitializing = false
    }
}
