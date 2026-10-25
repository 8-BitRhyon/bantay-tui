import SwiftUI
import UserNotifications

struct SettingsView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    /// Sidebar categories. Search hides whole categories with no match; a
    /// category with matches shows all its (matching) sections.
    private enum Category: String, CaseIterable, Identifiable {
        case general = "General"
        case agents = "Agents"
        case notch = "Notch"
        case desktop = "Desktop"
        case notifications = "Notifications"
        case integrations = "Integrations"
        case advanced = "Advanced"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .agents: "terminal"
            case .notch: "laptopcomputer"
            case .desktop: "rectangle.split.3x1"
            case .notifications: "bell"
            case .integrations: "link"
            case .advanced: "wrench.and.screwdriver"
            }
        }

        /// Maps a settings deep-link route to its sidebar category.
        static func from(route: SettingsRoute) -> Category {
            switch route {
            case .general: return .general
            case .agents, .approvals: return .agents
            case .notch: return .notch
            case .desktop: return .desktop
            case .notifications: return .notifications
            case .integrations: return .integrations
            case .advanced: return .advanced
            }
        }
    }

    @State private var selectedCategory: Category = .general
    @State private var searchText = ""

    @State private var captureEnabled = NotchHUDConfig.shared.captureEnabled
    @State private var captureInterval = Int(NotchHUDConfig.shared.captureInterval)
    @State private var enableAlerts = NotchHUDConfig.shared.enableAgentAlerts
    @State private var soundVolume = Int(NotchHUDConfig.shared.soundVolume * 100)
    @State private var autoClearTTL = Int(NotchHUDConfig.shared.autoClearTTL)
    @State private var stickyTTL = Int(NotchHUDConfig.shared.stickyApprovalTTL)
    @State private var launchAtLogin = false
    @State private var isRefreshingConfig = false
    @State private var hideAtStartup = NotchHUDConfig.shared.hideAtStartup
    @State private var showIslandWhenIdle = NotchHUDConfig.shared.showIslandWhenIdle
    @State private var muteInTerminal = NotchHUDConfig.shared.muteInTerminal
    @State private var dockSide = NotchHUDConfig.shared.islandDockSide.rawValue
    @State private var idleStyle = NotchHUDConfig.shared.idleStyle.rawValue
    @State private var idleMaxChips = NotchHUDConfig.shared.clampedIdleMaxChips
    @State private var expandedGroupByState = NotchHUDConfig.shared.expandedGroupByState
    @State private var hotkeyApprove = NotchHUDConfig.shared.globalHotkeyApproveEnabled
    @State private var hotkeyDeny = NotchHUDConfig.shared.globalHotkeyDenyEnabled
    @State private var hotkeySnooze = NotchHUDConfig.shared.globalHotkeySnoozeEnabled
    @State private var keyboardShortcuts = NotchHUDConfig.shared.keyboardShortcuts
    @State private var edgeGlow = NotchHUDConfig.shared.edgeGlowEnabled
    @State private var showElapsed = NotchHUDConfig.shared.showElapsedTime
    @State private var menuBadge = NotchHUDConfig.shared.menuBarBadge
    @State private var standaloneScan = NotchHUDConfig.shared.standaloneScanEnabled
    @State private var showUsage = NotchHUDConfig.shared.usageTrackingEnabled
    @State private var dailyBudgetUSD = NotchHUDConfig.shared.dailyBudgetUSD
    @State private var notifyOnBudgetThresholds = NotchHUDConfig.shared.notifyOnBudgetThresholds
    @State private var notifyOnHighBurnRate = NotchHUDConfig.shared.notifyOnHighBurnRate
    @State private var confirmRiskyPrompts = NotchHUDConfig.shared.confirmRiskyPrompts
    @State private var riskyPatternsText = NotchHUDConfig.shared.riskyPromptPatterns
        .joined(separator: "\n")
    @State private var highBurnThresholdTPM = NotchHUDConfig.shared.highBurnThresholdTPM
    @State private var enforceBudgetLimit = NotchHUDConfig.shared.enforceBudgetLimit
    @State private var enableSpendGlow = NotchHUDConfig.shared.enableSpendGlow
    @State private var showNotchMascot = NotchHUDConfig.shared.showNotchMascot
    @State private var selectedMascotArchetype = NotchHUDConfig.shared.selectedMascotArchetype
    @State private var equippedAccessory = NotchHUDConfig.shared.equippedAccessory
    @State private var mascotXP = NotchHUDConfig.shared.mascotXP
    @State private var mascotLevel = NotchHUDConfig.shared.mascotLevel
    @State private var ingestEnabled = NotchHUDConfig.shared.ingestEnabled
    @State private var ingestPort = NotchHUDConfig.shared.ingestPort
    @State private var shelfLimit = NotchHUDConfig.shared.clampedShelfLimit
    @State private var shelfKeepDuration = NotchHUDConfig.shared.shelfKeepDuration
    @State private var followMouse = NotchHUDConfig.shared.followMouseScreen
    @State private var floatingPill = NotchHUDConfig.shared.floatingPillOnNoNotch
    @State private var showInFullScreen = NotchHUDConfig.shared.showInFullScreen
    @State private var avoidMenuBar = NotchHUDConfig.shared.avoidMenuBarIcons
    @State private var preferredTerminal = NotchHUDConfig.shared.preferredTerminalBundleID ?? ""
    @State private var claudeHookInstalled = NotchHUDConfig.shared.claudeHookInstalled
    @State private var mutedSources = NotchHUDConfig.shared.mutedSources
    @State private var quietHoursEnabled = NotchHUDConfig.shared.quietHoursEnabled
    @State private var quietHoursStart = NotchHUDConfig.shared.quietHoursStart
    @State private var quietHoursEnd = NotchHUDConfig.shared.quietHoursEnd
    @State private var notifyWhenHidden = NotchHUDConfig.shared.notifyWhenHidden
    @State private var ntfyTopic = NotchHUDConfig.shared.ntfyTopic
    @State private var ntfyServer = NotchHUDConfig.shared.ntfyServer
    @State private var ntfyCallbackURL = NotchHUDConfig.shared.ntfyCallbackURL
    @State private var tmuxStatusEnabled = NotchHUDConfig.shared.tmuxStatusEnabled
    @State private var attentionFilter = NotchHUDConfig.shared.attentionFilterEnabled
    @State private var volumePreviewTask: Task<Void, Never>?
    @State private var herdrPluginInstalled = HerdrPluginInstaller.isInstalled(
        manifestPath: Self.herdrManifestPath)
    @State private var opencodePluginInstalled = OpenCodePluginInstaller.isInstalled()
    @State private var opencodePluginError = ""
    @State private var showTokenRate = NotchHUDConfig.shared.showTokenRate
    @State private var showAgentsTab = NotchHUDConfig.shared.showAgentsTab
    @State private var showTasksTab = NotchHUDConfig.shared.showTasksTab
    @State private var showHistoryTab = NotchHUDConfig.shared.showHistoryTab
    @State private var showShelfTab = NotchHUDConfig.shared.showShelfTab
    @State private var showMediaTab = NotchHUDConfig.shared.showMediaTab
    @State private var showNotesTab = NotchHUDConfig.shared.showNotesTab
    @State private var hoverSensitivity = NotchHUDConfig.shared.hoverSensitivityPreset
    @State private var enableQuotaAxiGauge = NotchHUDConfig.shared.enableQuotaAxiGauge
    @State private var quotaBadgeThreshold = NotchHUDConfig.shared.quotaBadgeThresholdPercent
    @State private var desktopHUDAutoHide = NotchHUDConfig.shared.desktopHUDAutoHideSeconds
    @State private var soundThemePreset = NotchHUDConfig.shared.soundThemePreset
    @State private var approvalSoundName = NotchHUDConfig.shared.approvalSoundName
    @State private var completionSoundName = NotchHUDConfig.shared.completionSoundName
    @State private var errorSoundName = NotchHUDConfig.shared.errorSoundName
    @State private var workingSoundName = NotchHUDConfig.shared.workingSoundName
    @State private var autoDispatchTasks = NotchHUDConfig.shared.autoDispatchTasks
    @State private var focusTerminalOnDispatch = NotchHUDConfig.shared.focusTerminalOnDispatch

    @State private var stripEnabled = StripConfiguration.load().isEnabled
    @State private var stripGap = StripConfiguration.load().gap
    @State private var stripInset = StripConfiguration.load().inset
    @State private var stripAutoCenter = StripConfiguration.load().autoCenterOnApproval
    @State private var stripHalos = StripConfiguration.load().statusHalosEnabled
    @State private var stripHotkeys = StripConfiguration.load().hotkeysEnabled
    @State private var stripWidthPreset = StripConfiguration.load().defaultWidthPreset
    @State private var stripSpringOmega = StripConfiguration.load().springOmega
    @State private var stripDimInactive = StripConfiguration.load().dimInactive
    @State private var stripChevrons = StripConfiguration.load().showNavigationChevrons
    @State private var stripIndicator = StripConfiguration.load().showStripIndicator
    @State private var stripKeepHeight = StripConfiguration.load().keepOriginalHeight
    @State private var stripFloatFixed = StripConfiguration.load().floatFixedSizeWindows
    @State private var stripFloatStubborn = StripConfiguration.load().floatStubbornWindows
    @State private var stripDisabledDisplays = StripConfiguration.load().disabledDisplayKeys
    @State private var desktopHUDPinned = DesktopHUDController.shared.isPinned
    @State private var openCodeGoAllowanceUSD = NotchHUDConfig.shared.openCodeGoAllowanceUSD
    @State private var hasAccessibility = StripWindowRegistry.hasAccessibilityPermission()

    private static let sectionKeywords: [String: [String]] = [
        "Startup": [
            "launch at login", "hide island at startup", "show island when idle", "idle position",
            "idle display", "agent name chips", "status dots", "count summary", "max agent chips",
            "dock",
        ],
        "Quick actions": [
            "global shortcut", "option space", "hotkey", "keyboard shortcuts in roster", "approve",
            "deny",
            "edge glow", "pending approvals", "elapsed time", "menu-bar badge",
        ],
        "Displays": [
            "follow mouse screen", "floating pill without notch", "clamshell", "external display",
            "full screen", "avoid menu-bar icons", "bartender", "ice", "focus terminal", "ghostty",
            "warp", "wezterm", "alacritty", "iterm2", "terminal", "vscode",
        ],
        "Pill behavior": [
            "auto-clear", "sticky approvals", "ttl", "timeout",
        ],
        "Mascot & Pet Companion": [
            "mascot", "pet", "companion", "dog", "cat", "cybercat", "ceo", "wizard", "dragon",
            "coffee", "xp", "level", "accessory", "hat", "glasses", "crown", "bowtie", "archetype",
            "eyes",
        ],
        "Expanded panel": [
            "modular tabs", "agents roster tab", "tasks & reminders tab", "session history tab",
            "drop shelf", "media tab", "quick notes tab", "scratchpad", "attention-only triage",
            "hover sensitivity", "quota-axi", "global hotkey",
        ],
        "Muted sources": [
            "mute", "muted sources", "hide source", "unmute",
        ],
        "Approval safety": [
            "approval", "approve", "deny", "risk", "policy", "allow once",
            "permission prompt", "risky patterns", "second click", "confirm",
        ],
        "Desktop HUD": [
            "desktop hud", "pin desktop", "auto-hide", "bottom dock", "spatial",
        ],
        "Tasks & Dispatching": [
            "auto-run tasks", "dispatch", "focus terminal or app", "reminders", "apple reminders",
        ],
        "Infinite Strip": [
            "strip", "canvas", "scrolling", "window manager", "tiling", "paperwm",
            "niri", "chainyourmac", "halos", "columns", "hotkeys", "shortcuts",
            "approval", "jump", "stack", "unstack", "gap", "inset", "spring",
        ],
        "Strip Canvas": [
            "strip", "gap", "margin", "inset", "width", "columns", "tiling", "canvas",
        ],
        "Navigation & Shortcuts": [
            "hotkey", "shortcut", "h", "l", "f", "r", "c", "a", "vim", "navigation",
        ],
        "Shelf": [
            "shelf tab", "clipboard history", "dropped files", "shelf limit", "expire", "duration",
        ],
        "Alerts": [
            "alert sounds", "volume", "sound theme preset", "8-bit arcade", "sci-fi synth",
            "retro synth", "minimalist", "industrial", "custom", "approval sound",
            "completion sound",
            "error sound", "mute while in terminal", "notify when hidden", "preview", "audio",
        ],
        "Push notifications (ntfy.sh)": [
            "push notifications", "ntfy", "topic", "server", "remote devices",
        ],
        "tmux status bar": [
            "tmux", "status bar", "status-right", "live summary",
        ],
        "Quiet hours": [
            "quiet hours", "silence alert sounds", "schedule", "night", "dnd", "do not disturb",
        ],
        "herdr integration": [
            "herdr", "plugin", "adapter", "socket",
        ],
        "Claude Code hook": [
            "claude code", "hook", "permissionprompt", "stop hook", "settings.json",
        ],
        "openCode integration": [
            "opencode", "plugin", "sessions",
        ],
        "Remote ingest (SSH bridge)": [
            "remote ingest", "ssh bridge", "listen port", "curl", "events", "token",
        ],
        "Capture": [
            "poll agents", "interval", "scan standalone agents", "codex", "gemini", "cursor",
            "opencode", "track token", "cost usage", "spend", "budget", "daily budget limit",
            "spend edge-glow", "notify at budget thresholds", "token burn rate", "tpm",
            "enforce budget limit", "block task dispatch",
        ],
    ]

    /// Whether a section title matches the current search query or its keywords.
    private func matchesSearch(_ title: String) -> Bool {
        guard !searchText.isEmpty else { return true }
        if title.localizedCaseInsensitiveContains(searchText) { return true }
        if let keywords = Self.sectionKeywords[title] {
            return keywords.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
        return false
    }

    private var activeRiskyPatternCount: Int {
        IslandMetrics.normalizedRiskyPatterns(riskyPatternsText).count
    }

    private func saveRiskyPatterns() {
        let patterns = IslandMetrics.normalizedRiskyPatterns(riskyPatternsText)
        guard patterns != NotchHUDConfig.shared.riskyPromptPatterns else { return }
        NotchHUDConfig.shared.riskyPromptPatterns = patterns
    }

    /// Sidebar row: icon + label, styled with BantayTheme tokens.
    private func sidebarRow(_ category: Category, matches: Bool) -> some View {
        Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .foregroundStyle(
                        selectedCategory == category
                            ? BantayTheme.statusWorking : BantayTheme.textSecondary)
                Text(category.rawValue)
                    .font(
                        .system(
                            size: 12, weight: selectedCategory == category ? .semibold : .medium)
                    )
                    .foregroundStyle(
                        selectedCategory == category
                            ? BantayTheme.textPrimary : BantayTheme.textSecondary)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            selectedCategory == category
                ? BantayTheme.statusWorking.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: BantayTheme.radiusSmall, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BantayTheme.radiusSmall, style: .continuous)
                .stroke(
                    selectedCategory == category
                        ? BantayTheme.statusWorking.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .opacity(matches ? 1 : 0.35)
        .disabled(!matches)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "square.3.layers.3d.top.filled")
                        .font(.system(size: 14))
                        .foregroundStyle(BantayTheme.statusWorking)
                    Text("Bantay-TUI")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(BantayTheme.textPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(BantayTheme.textTertiary)
                    TextField("Search settings...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(BantayTheme.textPrimary)
                        .disableAutocorrection(true)
                        .onChange(of: searchText) { query in
                            // Jump to the first category with a match so the
                            // results are immediately visible while typing.
                            guard !query.isEmpty else { return }
                            let first = Category.allCases.first {
                                $0.rawValue.localizedCaseInsensitiveContains(query)
                                    || sectionTitles(for: $0).contains { matchesSearch($0) }
                            }
                            if let first { selectedCategory = first }
                        }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(BantayTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: BantayTheme.radiusSmall, style: .continuous)
                        .fill(BantayTheme.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BantayTheme.radiusSmall, style: .continuous)
                        .stroke(BantayTheme.borderSubtle, lineWidth: 1)
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 10)

                ForEach(Category.allCases) { category in
                    sidebarRow(
                        category,
                        matches: categoryHasMatch(category)
                    )
                    .padding(.horizontal, 8)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 195)
            .padding(.top, 40)
            .background(BantayTheme.sidebarBackground)

            Divider()
                .overlay(BantayTheme.borderSubtle)

            // Right content panel.
            Group {
                if searchText.isEmpty || categoryHasMatch(selectedCategory) {
                    Form {
                        settingsSections
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .padding(.top, 16)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundColor(BantayTheme.textTertiary)
                        Text("No settings match “\(searchText)”")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(BantayTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BantayTheme.panelBackground)
        }
        .frame(width: 760, height: 620)
        .preferredColorScheme(.dark)
        .background(BantayTheme.panelBackground)
        .onAppear {
            AppDelegate.dbg("SettingsView.onAppear")
            refreshFromConfig()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsWillOpen)) { _ in
            AppDelegate.dbg("SettingsView: settingsWillOpen received")
            DispatchQueue.main.async { refreshFromConfig() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsRouteRequested)) { note in
            guard let raw = note.userInfo?["route"] as? String,
                let route = SettingsRoute(rawValue: raw)
            else { return }
            DispatchQueue.main.async { applyRoute(route) }
        }
    }

    /// Deep-link navigation for the single shared modal: select the route's
    /// category and filter to its section via the existing search.
    private func applyRoute(_ route: SettingsRoute) {
        selectedCategory = Category.from(route: route)
        searchText = route.sectionTitle ?? ""
    }

    /// Whether any section in a category matches the current search.
    private func categoryHasMatch(_ category: Category) -> Bool {
        if searchText.isEmpty { return true }
        return sectionTitles(for: category).contains { matchesSearch($0) }
    }

    /// The section titles that belong to a category (drives search matching).
    private func sectionTitles(for category: Category) -> [String] {
        switch category {
        case .general:
            ["Startup", "Quick actions", "Displays", "Welcome"]
        case .notch:
            ["Pill behavior", "Expanded panel", "Mascot & Pet Companion", "Shelf"]
        case .agents:
            ["Approval safety", "Muted sources", "Tasks & Dispatching"]
        case .desktop:
            ["Infinite Strip", "Strip Canvas", "Navigation & Shortcuts", "Desktop HUD"]
        case .notifications:
            ["Alerts", "Push notifications (ntfy.sh)", "Quiet hours", "tmux status bar"]
        case .integrations:
            [
                "herdr integration", "Claude Code hook", "openCode integration",
                "Remote ingest (SSH bridge)",
            ]
        case .advanced:
            ["Capture"]
        }
    }
    /// All settings sections, gated by the selected sidebar category and
    /// the search query. Each `Section` only renders when its category is
    /// active and its title matches the search.
    @ViewBuilder
    private var settingsSections: some View {
        Group {
            if selectedCategory == .advanced && matchesSearch("Capture") {
                Section("Capture") {
                    Toggle("Poll agents", isOn: $captureEnabled)
                        .onChange(of: captureEnabled) { newValue in
                            NotchHUDConfig.shared.captureEnabled = newValue
                            if newValue {
                                AgentEventManager.shared.startCapture()
                            } else {
                                AgentEventManager.shared.stopCapture()
                            }
                        }
                    Stepper(
                        "Poll interval: \(captureInterval) s",
                        value: $captureInterval, in: 1...60
                    )
                    .onChange(of: captureInterval) { newValue in
                        NotchHUDConfig.shared.captureInterval = Double(newValue)
                    }
                    Toggle("Scan standalone agents", isOn: $standaloneScan)
                        .help(
                            "Detect Claude Code, Codex, Gemini, Cursor, and opencode "
                                + "running outside any multiplexer."
                        )
                        .onChange(of: standaloneScan) { newValue in
                            NotchHUDConfig.shared.standaloneScanEnabled = newValue
                        }
                    Toggle("Track token/cost usage", isOn: $showUsage)
                        .help(
                            "Reads agent transcripts to compute token + cost usage."
                        )
                        .onChange(of: showUsage) { newValue in
                            NotchHUDConfig.shared.usageTrackingEnabled = newValue
                        }
                    Toggle("Notch spend edge-glow", isOn: $enableSpendGlow)
                        .help(
                            "Pulsing cyan/amber/red ambient perimeter stroke around the notch "
                                + "indicating live daily AI spend."
                        )
                        .onChange(of: enableSpendGlow) { newValue in
                            NotchHUDConfig.shared.enableSpendGlow = newValue
                        }
                    Stepper(
                        "Daily budget limit: $\(Int(dailyBudgetUSD))",
                        value: $dailyBudgetUSD, in: 1...100
                    )
                    .onChange(of: dailyBudgetUSD) { newValue in
                        NotchHUDConfig.shared.dailyBudgetUSD = Double(newValue)
                    }
                    Stepper(
                        "Go monthly allowance: $\(Int(openCodeGoAllowanceUSD))",
                        value: $openCodeGoAllowanceUSD, in: 10...1000, step: 10
                    )
                    .help(
                        "Bundled OpenCode Go monthly pool. Bantay meters every Go model against it. Match the figure on your console usage page."
                    )
                    .onChange(of: openCodeGoAllowanceUSD) { newValue in
                        NotchHUDConfig.shared.openCodeGoAllowanceUSD = newValue
                        Task { await QuotaMonitor.shared.refresh(force: true) }
                    }
                    Toggle(
                        "Notify at 80% and 100% budget thresholds",
                        isOn: $notifyOnBudgetThresholds
                    )
                    .help(
                        "Sends warning and alarm notifications when daily spend reaches 80% and 100%."
                    )
                    .onChange(of: notifyOnBudgetThresholds) { newValue in
                        NotchHUDConfig.shared.notifyOnBudgetThresholds = newValue
                    }
                    Toggle(
                        "Alert on high token burn rate (⚡ > \(highBurnThresholdTPM) tpm)",
                        isOn: $notifyOnHighBurnRate
                    )
                    .help(
                        "Notifies when agents consume tokens at an excessively high rate."
                    )
                    .onChange(of: notifyOnHighBurnRate) { newValue in
                        NotchHUDConfig.shared.notifyOnHighBurnRate = newValue
                    }
                    Stepper(
                        "High burn threshold: \(highBurnThresholdTPM) tpm",
                        value: $highBurnThresholdTPM, in: 500...20_000, step: 250
                    )
                    .help("Token rate that counts as a high-burn alert.")
                    .onChange(of: highBurnThresholdTPM) { newValue in
                        NotchHUDConfig.shared.highBurnThresholdTPM = newValue
                    }
                    Toggle(
                        "Enforce budget limit (block task dispatch)",
                        isOn: $enforceBudgetLimit
                    )
                    .help("Blocks new task dispatches when the daily budget is exhausted.")
                    .onChange(of: enforceBudgetLimit) { newValue in
                        NotchHUDConfig.shared.enforceBudgetLimit = newValue
                    }
                }
            }

            if selectedCategory == .agents && matchesSearch("Approval safety") {
                Section("Approval safety") {
                    Text(
                        "Every approval shows the exact command, file, or question before it runs. Allow Once approves a single request; Deny blocks it. Nothing auto-approves."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    Text("Risk tiers: High (destructive shell, remote scripts, deploys).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Medium (edits, pushes, permission changes). Low (reads, status checks).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Divider()
                    Toggle("Ask twice for risky approvals", isOn: $confirmRiskyPrompts)
                        .help(
                            "Adds a second Confirm click when the request matches one of the patterns below."
                        )
                        .onChange(of: confirmRiskyPrompts) { newValue in
                            NotchHUDConfig.shared.confirmRiskyPrompts = newValue
                        }
                    if confirmRiskyPrompts {
                        Text("Patterns (one per line, case-insensitive substrings).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $riskyPatternsText)
                            .font(.system(size: 11, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .foregroundColor(.primary)
                            .frame(minHeight: 72, maxHeight: 110)
                            .padding(4)
                            .background(Color.black.opacity(0.16))
                            .cornerRadius(6)
                            .onChange(of: riskyPatternsText) { _ in
                                saveRiskyPatterns()
                            }
                        HStack {
                            Text("\(activeRiskyPatternCount) active")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Reset to defaults") {
                                riskyPatternsText =
                                    IslandMetrics.defaultRiskyPromptPatterns
                                    .joined(separator: "\n")
                                saveRiskyPatterns()
                            }
                            .controlSize(.small)
                        }
                        if activeRiskyPatternCount == 0 {
                            Text("No patterns: risky approvals use one click.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    Button("Open Agents inbox") {
                        NotificationCenter.default.post(
                            name: .notchExpandRequested, object: nil)
                    }
                    .buttonStyle(.link)
                    .help("Expand the notch to the Agents inbox.")
                }
            }

            if selectedCategory == .agents && matchesSearch("Muted sources") {
                Section("Muted sources") {
                    if mutedSources.isEmpty {
                        Text(
                            "Nothing muted — right-click an agent row and pick Mute to hide a source."
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    } else {
                        ForEach(mutedSources.sorted(), id: \.self) { source in
                            HStack {
                                Text(source)
                                Spacer()
                                Button("Unmute") {
                                    NotchHUDConfig.shared.mutedSources.remove(source)
                                    mutedSources.remove(source)
                                }
                            }
                        }
                    }
                }
            }

            if selectedCategory == .agents && matchesSearch("Tasks & Dispatching") {
                Section("Tasks & Dispatching") {
                    Toggle("Auto-run tasks on creation", isOn: $autoDispatchTasks)
                        .help(
                            "Automatically dispatch tasks to target agent when created with @agent tag."
                        )
                        .onChange(of: autoDispatchTasks) { newValue in
                            NotchHUDConfig.shared.autoDispatchTasks = newValue
                        }
                    Toggle("Focus terminal or app on dispatch", isOn: $focusTerminalOnDispatch)
                        .help(
                            "Bring the agent's terminal pane or desktop IDE window into focus when dispatching."
                        )
                        .onChange(of: focusTerminalOnDispatch) { newValue in
                            NotchHUDConfig.shared.focusTerminalOnDispatch = newValue
                        }
                }
            }

            if selectedCategory == .integrations && matchesSearch("Remote ingest (SSH bridge)") {
                Section("Remote ingest (SSH bridge)") {
                    Toggle("Listen for remote events", isOn: $ingestEnabled)
                        .help(
                            "Accepts event lines from remote agents over "
                                + "`ssh -R <port>:localhost:<port>`."
                        )
                        .onChange(of: ingestEnabled) { newValue in
                            NotchHUDConfig.shared.ingestEnabled = newValue
                            AppDelegate.shared?.updateIngestServer()
                        }
                    Stepper("Listen port: \(ingestPort)", value: $ingestPort, in: 1024...65535)
                        .help("Localhost only; tunnel with SSH port forwarding.")
                        .onChange(of: ingestPort) { newValue in
                            NotchHUDConfig.shared.ingestPort = newValue
                            AppDelegate.shared?.updateIngestServer()
                        }
                    Text("Remote hook: ssh -R \(ingestPort):localhost:\(ingestPort) devbox")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("Then POST with the token:")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text(
                        "curl -s -X POST --data-binary @- "
                            + "\"http://127.0.0.1:\(ingestPort)/events?token="
                            + "\(NotchHUDConfig.shared.ingestToken)\""
                    )
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                }
            }

            if selectedCategory == .integrations && matchesSearch("Claude Code hook") {
                Section("Claude Code hook") {
                    Toggle("Install Claude Code hook", isOn: $claudeHookInstalled)
                        .help(
                            "Adds PermissionPrompt/Stop hooks to ~/.claude/settings.json "
                                + "that stream approvals to the island - no herdr needed. "
                                + "Also enables the local ingest listener."
                        )
                        .onChange(of: claudeHookInstalled) { newValue in
                            guard newValue != NotchHUDConfig.shared.claudeHookInstalled else {
                                return
                            }
                            installClaudeHook(newValue)
                        }
                }
            }

            if selectedCategory == .integrations && matchesSearch("herdr integration") {
                Section("herdr integration") {
                    Toggle("Stream herdr events", isOn: $herdrPluginInstalled)
                        .help(
                            "Installs the event adapter + plugin manifest into the app's "
                                + "data folder and registers it with herdr (plugin.link). "
                                + "No repository checkout needed."
                        )
                        .onChange(of: herdrPluginInstalled) { newValue in
                            if newValue {
                                installHerdrPlugin()
                            } else {
                                uninstallHerdrPlugin()
                            }
                        }
                }
            }

            if selectedCategory == .integrations && matchesSearch("openCode integration") {
                Section("openCode integration") {
                    Toggle("Stream openCode events", isOn: $opencodePluginInstalled)
                        .help(
                            "Installs a plugin into ~/.config/opencode/plugins so "
                                + "openCode sessions show on the notch (working / "
                                + "needs approval / done / failed). No-op when "
                                + "Bantay isn't running."
                        )
                        .onChange(of: opencodePluginInstalled) { newValue in
                            if newValue {
                                opencodePluginError =
                                    OpenCodePluginInstaller.install() ?? ""
                                opencodePluginInstalled = OpenCodePluginInstaller.isInstalled()
                            } else {
                                let error = OpenCodePluginInstaller.remove() ?? ""
                                opencodePluginError = error
                                if error.isEmpty {
                                    opencodePluginInstalled = false
                                } else {
                                    opencodePluginInstalled = OpenCodePluginInstaller.isInstalled()
                                }
                            }
                        }
                    if !opencodePluginError.isEmpty {
                        Text(opencodePluginError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            if selectedCategory == .notch && matchesSearch("Shelf") {
                Section("Shelf") {
                    Stepper("Shelf limit: \(shelfLimit)", value: $shelfLimit, in: 1...50)
                        .onChange(of: shelfLimit) { newValue in
                            NotchHUDConfig.shared.shelfLimit = newValue
                        }
                    Picker("Keep files for", selection: $shelfKeepDuration) {
                        ForEach(ShelfKeepDuration.allCases) { option in
                            Text(option.rawValue).tag(option.rawValue)
                        }
                    }
                    .help("Dropped files auto-expire after this long.")
                    .onChange(of: shelfKeepDuration) { newValue in
                        NotchHUDConfig.shared.shelfKeepDuration = newValue
                        ShelfStore.shared.cleanExpired()
                    }
                }
            }

            if selectedCategory == .notch && matchesSearch("Roster") {
                Section("Roster") {
                    Toggle(
                        "Group agents by execution state",
                        isOn: $expandedGroupByState
                    )
                    .help("Groups the roster into Working, Waiting, and Done sections.")
                    .onChange(of: expandedGroupByState) { newValue in
                        NotchHUDConfig.shared.expandedGroupByState = newValue
                    }
                    Toggle("Show token rate", isOn: $showTokenRate)
                        .help("Shows tokens per minute in the header.")
                        .onChange(of: showTokenRate) { newValue in
                            NotchHUDConfig.shared.showTokenRate = newValue
                        }
                }
            }

            if selectedCategory == .desktop && matchesSearch("Strip Canvas") {
                Section("Strip Canvas (Infinite Scrolling)") {
                    Toggle("Enable infinite strip layout", isOn: $stripEnabled)
                        .help(
                            "Tiles all active windows side-by-side on an endless horizontal strip without shrinking."
                        )
                        .onChange(of: stripEnabled) { newValue in
                            stripEnabled = newValue
                            updateStripConfig()
                            StripWindowManager.shared.toggle(enabled: newValue)
                        }

                    if !hasAccessibility {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                            Text("Accessibility permissions required to move and tile windows.")
                                .font(.system(size: 11))
                            Spacer()
                            Button("Grant Access") {
                                StripWindowRegistry.promptAccessibilityPermission()
                                hasAccessibility = StripWindowRegistry.hasAccessibilityPermission()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(Color.yellow.opacity(0.1))
                        .cornerRadius(6)
                    }

                    Stepper(
                        "Window gap: \(Int(stripGap)) pt", value: $stripGap, in: 0...48, step: 2
                    )
                    .onChange(of: stripGap) { _ in updateStripConfig() }

                    Stepper(
                        "Edge margins: \(Int(stripInset)) pt", value: $stripInset, in: 0...64,
                        step: 2
                    )
                    .onChange(of: stripInset) { _ in updateStripConfig() }

                    Picker("Default column width", selection: $stripWidthPreset) {
                        Text("33% (One Third)").tag(1.0 / 3.0)
                        Text("50% (Half Screen)").tag(0.5)
                        Text("66% (Two Thirds)").tag(2.0 / 3.0)
                        Text("100% (Full Display)").tag(1.0)
                    }
                    .onChange(of: stripWidthPreset) { _ in updateStripConfig() }

                    Stepper(
                        "Spring physics omega: \(Int(stripSpringOmega))", value: $stripSpringOmega,
                        in: 8...26, step: 1
                    )
                    .help("Stiffness of the smooth spring animation when scrolling.")
                    .onChange(of: stripSpringOmega) { _ in updateStripConfig() }
                }
            }

            if selectedCategory == .desktop && matchesSearch("Infinite Strip") {
                Section("Agent Awareness & Halos") {
                    Toggle("Agent status border halos", isOn: $stripHalos)
                        .help(
                            "Displays floating border halos: Amber for approval, Cyan for working, Green for finished."
                        )
                        .onChange(of: stripHalos) { _ in updateStripConfig() }

                    Toggle("Auto-jump to agent when approval needed (⌃⌥A)", isOn: $stripAutoCenter)
                        .help(
                            "Smoothly spring-scrolls the viewport directly to the blocked agent window."
                        )
                        .onChange(of: stripAutoCenter) { _ in updateStripConfig() }
                }
            }

            if selectedCategory == .desktop && matchesSearch("Navigation & Shortcuts") {
                Section("Navigation & Shortcuts (hold ⌃⌥)") {
                    Toggle("Enable strip global hotkeys", isOn: $stripHotkeys)
                        .onChange(of: stripHotkeys) { _ in updateStripConfig() }
                    let conflicts = StripConflictDetector.running()
                    if !conflicts.isEmpty {
                        Text(
                            "Also running: \(conflicts.joined(separator: ", ")). "
                                + "Two window managers can fight over the same window."
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    ForEach(displayOptions, id: \.key) { display in
                        Toggle(
                            "Tile windows on \(display.name)",
                            isOn: Binding(
                                get: { !stripDisabledDisplays.contains(display.key) },
                                set: { enabled in
                                    if enabled {
                                        stripDisabledDisplays.removeAll { $0 == display.key }
                                    } else if !stripDisabledDisplays.contains(display.key) {
                                        stripDisabledDisplays.append(display.key)
                                    }
                                    updateStripConfig()
                                })
                        )
                        .help("Turning this off leaves every window on that display alone.")
                    }
                    Toggle("Keep each window's original height", isOn: $stripKeepHeight)
                        .help("Windows keep the height they opened with, aligned to the top.")
                        .onChange(of: stripKeepHeight) { _ in updateStripConfig() }
                    Toggle("Float fixed-size windows", isOn: $stripFloatFixed)
                        .help("Calculator, palettes, and dialogs stay where the app puts them.")
                        .onChange(of: stripFloatFixed) { _ in updateStripConfig() }
                    Toggle("Float windows that refuse resizing", isOn: $stripFloatStubborn)
                        .help("Stops fighting an app that keeps snapping its window back.")
                        .onChange(of: stripFloatStubborn) { _ in updateStripConfig() }
                    Toggle("Show strip indicator while navigating", isOn: $stripIndicator)
                        .help(
                            "Hold Control-Option to keep it on screen. Click a tile to jump, drag to reorder."
                        )
                        .onChange(of: stripIndicator) { _ in updateStripConfig() }
                    Toggle("Show edge navigation chevrons", isOn: $stripChevrons)
                        .help("Show clickable left and right arrows at the screen edges.")
                        .onChange(of: stripChevrons) { _ in updateStripConfig() }
                    Toggle("Dim inactive windows", isOn: $stripDimInactive)
                        .help("Darken windows outside the active column.")
                        .onChange(of: stripDimInactive) { _ in updateStripConfig() }

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("⌃⌥← / ⌃⌥→ (or H / L)").font(
                                .system(size: 11, weight: .bold, design: .monospaced))
                            Text("Focus previous / next column").foregroundColor(.secondary)
                        }
                        GridRow {
                            Text("⌃⌥↑ / ⌃⌥↓").font(
                                .system(size: 11, weight: .bold, design: .monospaced))
                            Text("Focus previous / next window in the active column")
                                .foregroundColor(
                                    .secondary
                                )
                        }
                        GridRow {
                            Text("⌃⌥Home / ⌃⌥End").font(
                                .system(size: 11, weight: .bold, design: .monospaced))
                            Text("Jump to the first / last column").foregroundColor(.secondary)
                        }
                        GridRow {
                            Text("⌃⌥1 … ⌃⌥9").font(
                                .system(size: 11, weight: .bold, design: .monospaced))
                            Text("Jump directly to a column").foregroundColor(.secondary)
                        }
                        GridRow {
                            Text("⌃⌥⇧← / ⌃⌥⇧→ (or ⇧H / ⇧L)").font(
                                .system(size: 11, weight: .bold, design: .monospaced))
                            Text("Move column left / right").foregroundColor(.secondary)
                        }
                        GridRow {
                            Text("⌃⌥R").font(.system(size: 11, weight: .bold, design: .monospaced))
                            Text("Cycle column width (25% → 33% → 50% → 67% → 75% → 100%)")
                                .foregroundColor(.secondary)
                        }
                        GridRow {
                            Text("⌃⌥F").font(.system(size: 11, weight: .bold, design: .monospaced))
                            Text("Toggle full width / restored width").foregroundColor(.secondary)
                        }
                        GridRow {
                            Text("⌃⌥C").font(.system(size: 11, weight: .bold, design: .monospaced))
                            Text("Center current column in display").foregroundColor(.secondary)
                        }
                        GridRow {
                            Text("⌃⌥A").font(.system(size: 11, weight: .bold, design: .monospaced))
                            Text("Jump directly to agent requesting approval").foregroundColor(
                                .secondary)
                        }
                        GridRow {
                            Text("⌃⌥M").font(.system(size: 11, weight: .bold, design: .monospaced))
                            Text("Chain every open window into the active project").foregroundColor(
                                .secondary)
                        }
                        GridRow {
                            Text("⌃⌥P").font(.system(size: 11, weight: .bold, design: .monospaced))
                            Text("Pin / unpin the active column").foregroundColor(.secondary)
                        }
                        GridRow {
                            Text("⌃⌥⇧T").font(.system(size: 11, weight: .bold, design: .monospaced))
                            Text("Toggle tabbed stacking for the active column").foregroundColor(
                                .secondary)
                        }
                        GridRow {
                            Text("⌃⌥] / ⌃⌥[").font(
                                .system(size: 11, weight: .bold, design: .monospaced))
                            Text("Stack the active window right / left").foregroundColor(.secondary)
                        }
                        GridRow {
                            Text("⌃⌥⇧] / ⌃⌥⇧[").font(
                                .system(size: 11, weight: .bold, design: .monospaced))
                            Text("Pop the active window out right / left").foregroundColor(
                                .secondary
                            )
                        }
                    }
                    .font(.system(size: 11))
                    .padding(.vertical, 4)
                }
            }

            if selectedCategory == .desktop && matchesSearch("Desktop HUD") {
                Section("Desktop HUD") {
                    Toggle("Pin Desktop HUD open", isOn: $desktopHUDPinned)
                        .help("Pinned HUD never auto-hides when the pointer leaves.")
                        .onChange(of: desktopHUDPinned) { newValue in
                            DesktopHUDController.shared.isPinned = newValue
                        }
                    Stepper(
                        "Auto-hide after \(String(format: "%.1f", desktopHUDAutoHide)) s",
                        value: $desktopHUDAutoHide, in: 0.5...10, step: 0.5
                    )
                    .help("Delay before the HUD hides after the pointer leaves, unless pinned.")
                    .onChange(of: desktopHUDAutoHide) { newValue in
                        NotchHUDConfig.shared.desktopHUDAutoHideSeconds = newValue
                    }
                    Text(
                        "Bottom-center window map. Never appears in full screen."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    Button("Open Desktop HUD") {
                        DesktopHUDController.shared.toggle()
                    }
                    .buttonStyle(.link)
                    .help("Toggle the Desktop strip HUD (⌃⌥Space).")
                }
            }

            if selectedCategory == .general && matchesSearch("Displays") {
                Section("Displays") {
                    Toggle("Follow mouse screen", isOn: $followMouse)
                        .help("Island moves to the notch on the display under the cursor.")
                        .onChange(of: followMouse) { newValue in
                            NotchHUDConfig.shared.followMouseScreen = newValue
                            NotificationCenter.default.post(
                                name: .notchVisibilityChanged, object: nil)
                        }
                    Toggle("Floating pill without notch", isOn: $floatingPill)
                        .help("External displays/clamshell get a centered pill below the menu bar.")
                        .onChange(of: floatingPill) { newValue in
                            NotchHUDConfig.shared.floatingPillOnNoNotch = newValue
                            NotificationCenter.default.post(
                                name: .notchVisibilityChanged, object: nil)
                        }
                    Toggle("Keep island in full screen", isOn: $showInFullScreen)
                        .help("Stay visible over full-screen apps; re-anchors after transitions.")
                        .onChange(of: showInFullScreen) { newValue in
                            NotchHUDConfig.shared.showInFullScreen = newValue
                            AppDelegate.applyFullScreenPolicy(
                                isFullScreen: FullScreenMonitor.shared.isFullScreen)
                        }
                    Toggle("Avoid menu-bar icons", isOn: $avoidMenuBar)
                        .help(
                            "Shrink idle chips so they never overlap status icons (Bartender/Ice safe)."
                        )
                        .onChange(of: avoidMenuBar) { newValue in
                            NotchHUDConfig.shared.avoidMenuBarIcons = newValue
                            NotificationCenter.default.post(
                                name: .notchVisibilityChanged, object: nil)
                        }
                    Picker("Focus terminal", selection: $preferredTerminal) {
                        Text("Auto").tag("")
                        ForEach(TerminalRegistry.preferredBundleIDs, id: \.self) { bundleID in
                            Text(terminalLabel(bundleID)).tag(bundleID)
                        }
                    }
                    .help(
                        "Which terminal 'Force focus' activates (Ghostty, Warp, WezTerm, Alacritty, iTerm2, Terminal, VSCode)."
                    )
                    .onChange(of: preferredTerminal) { newValue in
                        NotchHUDConfig.shared.preferredTerminalBundleID =
                            newValue.isEmpty ? nil : newValue
                    }
                }
            }

            if selectedCategory == .notifications && matchesSearch("Alerts") {
                Section("Alerts") {
                    Toggle("Alert sounds", isOn: $enableAlerts)
                        .onChange(of: enableAlerts) { newValue in
                            NotchHUDConfig.shared.enableAgentAlerts = newValue
                            if newValue {
                                playAlertSample()
                            }
                        }
                    Stepper(
                        "Volume: \(soundVolume)%",
                        value: $soundVolume, in: 0...100, step: 5
                    )
                    .onChange(of: soundVolume) { newValue in
                        NotchHUDConfig.shared.soundVolume = Float(newValue) / 100
                        previewAlertVolume()
                    }
                    Picker("Sound Theme Preset", selection: $soundThemePreset) {
                        Text("Sleek Modern (Default)").tag("Sleek Modern")
                        Text("8-Bit Arcade 🕹️").tag("8-Bit Arcade")
                        Text("Sci-Fi Synth 🚀").tag("Sci-Fi Synth")
                        Text("Retro Synth").tag("Retro Synth")
                        Text("Minimalist").tag("Minimalist")
                        Text("Industrial Alert").tag("Industrial")
                        Text("Custom").tag("Custom")
                    }
                    .onChange(of: soundThemePreset) { newValue in
                        NotchHUDConfig.shared.soundThemePreset = newValue
                        if newValue != "Custom" {
                            approvalSoundName = NotchHUDConfig.shared.approvalSoundName
                            completionSoundName = NotchHUDConfig.shared.completionSoundName
                            errorSoundName = NotchHUDConfig.shared.errorSoundName
                            workingSoundName = NotchHUDConfig.shared.workingSoundName
                        }
                    }

                    HStack {
                        Picker("Approval Sound", selection: $approvalSoundName) {
                            ForEach(
                                [
                                    "Glass", "Hero", "Ping", "Pop", "Tink", "Submarine", "Purr",
                                    "Morse", "Blow", "Funk", "Basso", "Sosumi", "Bottle", "Frog",
                                ], id: \.self
                            ) { sound in
                                Text(sound).tag(sound)
                            }
                        }
                        .onChange(of: approvalSoundName) { newValue in
                            NotchHUDConfig.shared.approvalSoundName = newValue
                            if soundThemePreset != "Custom" { soundThemePreset = "Custom" }
                        }
                        Button("▶ Test") {
                            NSSound(named: approvalSoundName)?.play()
                        }
                        .buttonStyle(.borderless)
                        .help("Preview approval sound")
                    }

                    HStack {
                        Picker("Completion Sound", selection: $completionSoundName) {
                            ForEach(
                                [
                                    "Glass", "Hero", "Ping", "Pop", "Tink", "Submarine", "Purr",
                                    "Morse", "Blow", "Funk", "Basso", "Sosumi", "Bottle", "Frog",
                                ], id: \.self
                            ) { sound in
                                Text(sound).tag(sound)
                            }
                        }
                        .onChange(of: completionSoundName) { newValue in
                            NotchHUDConfig.shared.completionSoundName = newValue
                            if soundThemePreset != "Custom" { soundThemePreset = "Custom" }
                        }
                        Button("▶ Test") {
                            NSSound(named: completionSoundName)?.play()
                        }
                        .buttonStyle(.borderless)
                        .help("Preview completion sound")
                    }

                    HStack {
                        Picker("Error Sound", selection: $errorSoundName) {
                            ForEach(
                                [
                                    "Glass", "Hero", "Ping", "Pop", "Tink", "Submarine", "Purr",
                                    "Morse", "Blow", "Funk", "Basso", "Sosumi", "Bottle", "Frog",
                                ], id: \.self
                            ) { sound in
                                Text(sound).tag(sound)
                            }
                        }
                        .onChange(of: errorSoundName) { newValue in
                            NotchHUDConfig.shared.errorSoundName = newValue
                            if soundThemePreset != "Custom" { soundThemePreset = "Custom" }
                        }
                        Button("▶ Test") {
                            NSSound(named: errorSoundName)?.play()
                        }
                        .buttonStyle(.borderless)
                        .help("Preview error sound")
                    }

                    HStack {
                        Picker("Working Sound", selection: $workingSoundName) {
                            ForEach(
                                [
                                    "Glass", "Hero", "Ping", "Pop", "Tink", "Submarine", "Purr",
                                    "Morse", "Blow", "Funk", "Basso", "Sosumi", "Bottle", "Frog",
                                ], id: \.self
                            ) { sound in
                                Text(sound).tag(sound)
                            }
                        }
                        .onChange(of: workingSoundName) { newValue in
                            NotchHUDConfig.shared.workingSoundName = newValue
                            if soundThemePreset != "Custom" { soundThemePreset = "Custom" }
                        }
                        Button("▶ Test") {
                            NSSound(named: workingSoundName)?.play()
                        }
                        .buttonStyle(.borderless)
                        .help("Preview working sound")
                    }

                    Toggle("Mute while in Terminal", isOn: $muteInTerminal)
                        .onChange(of: muteInTerminal) { newValue in
                            NotchHUDConfig.shared.muteInTerminal = newValue
                        }
                    Toggle("Notify when island hidden", isOn: $notifyWhenHidden)
                        .help(
                            "Approvals arriving while the island is hidden or "
                                + "snoozed post a Notification Center alert."
                        )
                        .onChange(of: notifyWhenHidden) { newValue in
                            NotchHUDConfig.shared.notifyWhenHidden = newValue
                            if newValue {
                                guard ApprovalNotificationController.hasBundleProxy else { return }
                                UNUserNotificationCenter.current()
                                    .requestAuthorization(options: [.alert, .sound]) {
                                        granted, _ in
                                        Task { @MainActor in
                                            guard !granted else { return }
                                            NotchHUDConfig.shared.notifyWhenHidden = false
                                            notifyWhenHidden = false
                                            let alert = NSAlert()
                                            alert.messageText = "Notifications are blocked"
                                            alert.informativeText =
                                                "Enable notifications for Bantay-TUI "
                                                + "in System Settings to use this."
                                            alert.runModal()
                                        }
                                    }
                            }
                        }
                    Button("Play alert sound preview") {
                        let names = ["Ping", "Glass", "Submarine"]
                        let name = names[Int.random(in: 0..<names.count)]
                        let sound = NSSound(named: name)
                        sound?.volume = NotchHUDConfig.shared.soundVolume
                        sound?.play()
                    }
                    #if DEBUG
                        FLXButton("Send test notification", variant: .secondary) {
                            AgentEventManager.shared.publishForTesting()
                        }
                    #else
                        Text("Test notification is available in debug builds only.")
                    #endif
                }
            }
        }

        Group {
            if selectedCategory == .notifications && matchesSearch("Push notifications (ntfy.sh)") {
                Section("Push notifications (ntfy.sh)") {
                    FLXTextField("Topic", text: $ntfyTopic)
                        .help(
                            "Leave empty to disable. Any ntfy topic works — "
                                + "create a private one at ntfy.sh first."
                        )
                        .onChange(of: ntfyTopic) { newValue in
                            NotchHUDConfig.shared.ntfyTopic = newValue
                        }
                    FLXTextField("Server", text: $ntfyServer)
                        .help("Default https://ntfy.sh — override for self-hosted.")
                        .onChange(of: ntfyServer) { newValue in
                            NotchHUDConfig.shared.ntfyServer = newValue
                        }
                    FLXTextField("Callback URL", text: $ntfyCallbackURL)
                        .help("Public/Tailscale URL for approvals (e.g. http://my-mac:41817).")
                        .onChange(of: ntfyCallbackURL) { newValue in
                            NotchHUDConfig.shared.ntfyCallbackURL = newValue
                        }
                    Text(
                        ntfyTopic.isEmpty
                            ? "Push is off — set a topic to receive approvals, failures and completions on other devices."
                            : "Push on: \(ntfyServer)/\(ntfyTopic)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if selectedCategory == .notifications && matchesSearch("tmux status bar") {
                Section("tmux status bar") {
                    Toggle("Show agent status in tmux", isOn: $tmuxStatusEnabled)
                        .help(
                            "Adds a live one-line summary (◐ working · ⚠ blocked) "
                                + "to tmux's status-right via bantay-status."
                        )
                        .onChange(of: tmuxStatusEnabled) { newValue in
                            NotchHUDConfig.shared.tmuxStatusEnabled = newValue
                            let script = TmuxStatusInstaller.scriptPath()
                            if newValue {
                                _ = TmuxStatusInstaller.install(scriptPath: script)
                            } else {
                                _ = TmuxStatusInstaller.remove(scriptPath: script)
                            }
                        }
                    Text(
                        TmuxStatusInstaller.isInstalled(
                            scriptPath: TmuxStatusInstaller.scriptPath())
                            ? "Installed — agent status shows in tmux status-right."
                            : "Not installed — enable above to add it to tmux."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if selectedCategory == .notifications && matchesSearch("Quiet hours") {
                Section("Quiet hours") {
                    Toggle("Silence alert sounds", isOn: $quietHoursEnabled)
                        .help(
                            "During the window, alert sounds are silenced. "
                                + "Approvals still appear on the island — nothing is missed."
                        )
                        .onChange(of: quietHoursEnabled) { newValue in
                            NotchHUDConfig.shared.quietHoursEnabled = newValue
                        }
                    Stepper(
                        "From \(timeLabel(quietHoursStart))",
                        value: $quietHoursStart, in: 0...1410, step: 30
                    )
                    .disabled(!quietHoursEnabled)
                    .onChange(of: quietHoursStart) { newValue in
                        NotchHUDConfig.shared.quietHoursStart = newValue
                    }
                    Stepper(
                        "To \(timeLabel(quietHoursEnd))",
                        value: $quietHoursEnd, in: 0...1410, step: 30
                    )
                    .disabled(!quietHoursEnabled)
                    .onChange(of: quietHoursEnd) { newValue in
                        NotchHUDConfig.shared.quietHoursEnd = newValue
                    }
                }
            }

            if selectedCategory == .notch && matchesSearch("Pill behavior") {
                Section("Pill behavior") {
                    Stepper("Auto-clear after \(autoClearTTL) s", value: $autoClearTTL, in: 1...30)
                        .onChange(of: autoClearTTL) { newValue in
                            NotchHUDConfig.shared.autoClearTTL = Double(newValue)
                        }
                    Stepper(
                        "Sticky approvals for \(stickyTTL) s",
                        value: $stickyTTL, in: 10...120, step: 5
                    )
                    .onChange(of: stickyTTL) { newValue in
                        NotchHUDConfig.shared.stickyApprovalTTL = Double(newValue)
                    }
                }
            }

            if selectedCategory == .notch && matchesSearch("Mascot & Pet Companion") {
                Section("Mascot & Pet Companion") {
                    Toggle("Show Mascot on Notch", isOn: $showNotchMascot)
                        .help(
                            "Displays a micro-animated desktop companion that reacts in real-time to agent states."
                        )
                        .onChange(of: showNotchMascot) { newValue in
                            NotchHUDConfig.shared.showNotchMascot = newValue
                        }

                    Picker("Mascot Archetype", selection: $selectedMascotArchetype) {
                        ForEach(MascotArchetype.allCases) { archetype in
                            Text(archetype.displayName).tag(archetype)
                        }
                    }
                    .disabled(!showNotchMascot)
                    .onChange(of: selectedMascotArchetype) { newValue in
                        NotchHUDConfig.shared.selectedMascotArchetype = newValue
                    }

                    Picker("Equipped Accessory", selection: $equippedAccessory) {
                        ForEach(MascotAccessory.allCases) { acc in
                            let locked = mascotLevel < acc.requiredLevel
                            Text(
                                locked
                                    ? "\(acc.displayName) (Requires Lv. \(acc.requiredLevel))"
                                    : acc.displayName
                            )
                            .tag(acc)
                        }
                    }
                    .disabled(!showNotchMascot)
                    .onChange(of: equippedAccessory) { newValue in
                        if mascotLevel >= newValue.requiredLevel {
                            NotchHUDConfig.shared.equippedAccessory = newValue
                        } else {
                            equippedAccessory = NotchHUDConfig.shared.equippedAccessory
                        }
                    }

                    if showNotchMascot {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Pet Level \(mascotLevel)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                                Spacer()
                                Text("\(mascotXP % 100) / 100 XP (Total: \(mascotXP) XP)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            ProgressView(value: Double(mascotXP % 100), total: 100)
                                .tint(.yellow)

                            Text(selectedMascotArchetype.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            LazyVGrid(
                                columns: [
                                    GridItem(.adaptive(minimum: 96, maximum: 110), spacing: 8)
                                ],
                                spacing: 8
                            ) {
                                ForEach(MascotState.allCases) { state in
                                    VStack(spacing: 6) {
                                        MascotView(
                                            archetype: selectedMascotArchetype,
                                            state: state,
                                            size: 22
                                        )
                                        .padding(.top, 4)

                                        Text(state.statusText)
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundColor(BantayTheme.color(for: state))
                                            .lineLimit(1)

                                        Text(
                                            "“\(selectedMascotArchetype.personalityQuote(for: state))”"
                                        )
                                        .font(.system(size: 8))
                                        .foregroundColor(BantayTheme.textTertiary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(height: 22)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        BantayTheme.cardBackground,
                                        in: RoundedRectangle(cornerRadius: BantayTheme.radiusMedium)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: BantayTheme.radiusMedium)
                                            .stroke(
                                                BantayTheme.color(for: state).opacity(0.25),
                                                lineWidth: 1)
                                    )
                                }
                            }
                            .padding(.top, 6)
                        }
                    }
                }
            }

            if selectedCategory == .general && matchesSearch("Startup") {
                Section("Startup") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .help("Runs the app at login; installs the launch agent on first enable.")
                        .onChange(of: launchAtLogin) { newValue in
                            guard !isRefreshingConfig else { return }
                            if !LaunchAgent.setLaunchAtLogin(newValue) {
                                launchAtLogin = false
                                let alert = NSAlert()
                                alert.messageText = "Could not enable launch at login"
                                alert.informativeText =
                                    "The launch agent could not be installed. "
                                    + "Check Console for bantay diagnostics."
                                alert.runModal()
                            }
                        }
                    Toggle("Hide island at startup", isOn: $hideAtStartup)
                        .help(
                            "Keep the island hidden after launch until an approval "
                                + "needs your attention (or you interact once)."
                        )
                        .onChange(of: hideAtStartup) { newValue in
                            NotchHUDConfig.shared.hideAtStartup = newValue
                        }
                    Toggle("Show island when idle", isOn: $showIslandWhenIdle)
                        .help(
                            "Keep the notch visible even with no agents or events — "
                                + "so you always know where Bantay lives."
                        )
                        .onChange(of: showIslandWhenIdle) { newValue in
                            NotchHUDConfig.shared.showIslandWhenIdle = newValue
                            NotificationCenter.default.post(
                                name: .notchVisibilityChanged, object: nil)
                        }
                    Picker("Idle position", selection: $dockSide) {
                        Text("Right of notch").tag("right")
                        Text("Left of notch").tag("left")
                        Text("Center").tag("center")
                    }
                    .onChange(of: dockSide) { newValue in
                        NotchHUDConfig.shared.islandDockSide =
                            IslandMetrics.IslandDockSide(rawValue: newValue) ?? .center
                        NotificationCenter.default.post(
                            name: .notchVisibilityChanged, object: nil)
                    }
                    Picker("Idle display", selection: $idleStyle) {
                        Text("Agent name chips").tag(IslandMetrics.IdleStyle.names.rawValue)
                        Text("Status dots only").tag(IslandMetrics.IdleStyle.dots.rawValue)
                        Text("Count summary").tag(IslandMetrics.IdleStyle.summary.rawValue)
                    }
                    .help("What the closed chip shows beside the notch while agents work.")
                    .onChange(of: idleStyle) { newValue in
                        NotchHUDConfig.shared.idleStyle =
                            IslandMetrics.IdleStyle(rawValue: newValue) ?? .names
                        NotificationCenter.default.post(
                            name: .notchVisibilityChanged, object: nil)
                    }
                    Stepper("Max agent chips: \(idleMaxChips)", value: $idleMaxChips, in: 1...6)
                        .help("Longer strips truncate to +N.")
                        .onChange(of: idleMaxChips) { newValue in
                            NotchHUDConfig.shared.idleMaxChips = newValue
                            NotificationCenter.default.post(
                                name: .notchVisibilityChanged, object: nil)
                        }
                }
            }

            if selectedCategory == .notch && matchesSearch("Expanded panel") {
                Section("Expanded panel & Modular tabs") {
                    Toggle("🤖 Agents Roster tab", isOn: $showAgentsTab)
                        .help("Enable or disable AI agent monitoring and roster in notch.")
                        .onChange(of: showAgentsTab) { newValue in
                            NotchHUDConfig.shared.showAgentsTab = newValue
                        }
                    Toggle("📋 Tasks & Reminders tab", isOn: $showTasksTab)
                        .help(
                            "Adds a Barrie-style Task Manager tab to the expanded Dynamic Island."
                        )
                        .onChange(of: showTasksTab) { newValue in
                            NotchHUDConfig.shared.showTasksTab = newValue
                        }
                    Toggle("📜 Session History tab", isOn: $showHistoryTab)
                        .help("Adds a Session History feed tab to the expanded Dynamic Island.")
                        .onChange(of: showHistoryTab) { newValue in
                            NotchHUDConfig.shared.showHistoryTab = newValue
                        }
                    Toggle("📁 Drop Shelf & Pasteboard tab", isOn: $showShelfTab)
                        .help("Adds a file drop shelf & pasteboard history tab to expanded island.")
                        .onChange(of: showShelfTab) { newValue in
                            NotchHUDConfig.shared.showShelfTab = newValue
                        }
                    Toggle("🎵 Now Playing Media tab", isOn: $showMediaTab)
                        .help("Adds Apple Music & Spotify player controls to expanded island.")
                        .onChange(of: showMediaTab) { newValue in
                            NotchHUDConfig.shared.showMediaTab = newValue
                        }
                    Toggle("📝 Quick Notes Scratchpad tab", isOn: $showNotesTab)
                        .help("Adds an auto-saving markdown quick notes tab to expanded island.")
                        .onChange(of: showNotesTab) { newValue in
                            NotchHUDConfig.shared.showNotesTab = newValue
                        }
                    Toggle("Attention-only triage tab", isOn: $attentionFilter)
                        .help(
                            "Adds an Attention tab showing only agents that need "
                                + "you or failed — the 'everything that needs me' triage."
                        )
                        .onChange(of: attentionFilter) { newValue in
                            NotchHUDConfig.shared.attentionFilterEnabled = newValue
                        }
                    Picker("Notch Hover Sensitivity", selection: $hoverSensitivity) {
                        Text("Instant (0.03s)").tag("Instant")
                        Text("Snappy (0.08s)").tag("Snappy")
                        Text("Balanced (0.18s)").tag("Balanced")
                        Text("Relaxed (0.35s)").tag("Relaxed")
                    }
                    .help("Adjust how quickly hovering over the notch expands the UI.")
                    .onChange(of: hoverSensitivity) { newValue in
                        NotchHUDConfig.shared.hoverSensitivityPreset = newValue
                    }
                    Toggle("Quota-Axi provider gauge", isOn: $enableQuotaAxiGauge)
                        .help("Displays live Quota-Axi provider percentage in header bar.")
                        .onChange(of: enableQuotaAxiGauge) { newValue in
                            NotchHUDConfig.shared.enableQuotaAxiGauge = newValue
                        }
                    Stepper(
                        "Quota badge below \(Int(quotaBadgeThreshold))%",
                        value: $quotaBadgeThreshold, in: 5...100, step: 5
                    )
                    .help(
                        "Header quota badge appears only when remaining quota drops below this percent."
                    )
                    .onChange(of: quotaBadgeThreshold) { newValue in
                        NotchHUDConfig.shared.quotaBadgeThresholdPercent = newValue
                    }
                }
            }

            if selectedCategory == .general && matchesSearch("Quick actions") {
                Section("Quick actions") {
                    Toggle("Keyboard shortcuts in roster", isOn: $keyboardShortcuts)
                        .help("With the island focused: Y approve, N deny, R reply, 1-9 choose.")
                        .onChange(of: keyboardShortcuts) { newValue in
                            NotchHUDConfig.shared.keyboardShortcuts = newValue
                        }
                    Toggle("Global approve hotkey (⌥Y)", isOn: $hotkeyApprove)
                        .help("Approve the top approval from any app.")
                        .onChange(of: hotkeyApprove) { newValue in
                            NotchHUDConfig.shared.globalHotkeyApproveEnabled = newValue
                            AppDelegate.shared?.updateGlobalHotkeyMonitor()
                        }
                    Toggle("Global deny hotkey (⌥N)", isOn: $hotkeyDeny)
                        .help("Deny the top approval from any app.")
                        .onChange(of: hotkeyDeny) { newValue in
                            NotchHUDConfig.shared.globalHotkeyDenyEnabled = newValue
                            AppDelegate.shared?.updateGlobalHotkeyMonitor()
                        }
                    Toggle("Global snooze hotkey (⌥S)", isOn: $hotkeySnooze)
                        .help("Snooze the island for 15 minutes from any app.")
                        .onChange(of: hotkeySnooze) { newValue in
                            NotchHUDConfig.shared.globalHotkeySnoozeEnabled = newValue
                            AppDelegate.shared?.updateGlobalHotkeyMonitor()
                        }
                    Toggle("Edge glow on pending approvals", isOn: $edgeGlow)
                        .help("Pulsing amber border when agents need you.")
                        .onChange(of: edgeGlow) { newValue in
                            NotchHUDConfig.shared.edgeGlowEnabled = newValue
                        }
                    Toggle("Elapsed time on working agents", isOn: $showElapsed)
                        .onChange(of: showElapsed) { newValue in
                            NotchHUDConfig.shared.showElapsedTime = newValue
                        }
                    Toggle("Menu-bar badge", isOn: $menuBadge)
                        .help("Amber dot + pending count in the menu bar.")
                        .onChange(of: menuBadge) { newValue in
                            NotchHUDConfig.shared.menuBarBadge = newValue
                        }
                }
            }

            if selectedCategory == .general && matchesSearch("Welcome") {
                Section {
                    Button("Show Welcome…") {
                        hasSeenOnboarding = false
                    }
                }
            }
        }
    }

    /// Re-read externally mutable state (menu-bar toggles, launch agent
    /// status, hook installs) so a persisted Settings window never shows
    /// stale toggles.
    private func refreshFromConfig() {
        isRefreshingConfig = true
        captureEnabled = NotchHUDConfig.shared.captureEnabled
        enableAlerts = NotchHUDConfig.shared.enableAgentAlerts
        confirmRiskyPrompts = NotchHUDConfig.shared.confirmRiskyPrompts
        riskyPatternsText = NotchHUDConfig.shared.riskyPromptPatterns
            .joined(separator: "\n")
        notifyWhenHidden = NotchHUDConfig.shared.notifyWhenHidden
        quietHoursEnabled = NotchHUDConfig.shared.quietHoursEnabled
        mutedSources = NotchHUDConfig.shared.mutedSources
        claudeHookInstalled = NotchHUDConfig.shared.claudeHookInstalled
        herdrPluginInstalled = HerdrPluginInstaller.isInstalled(
            manifestPath: Self.herdrManifestPath)
        let stripCfg = StripConfiguration.load()
        stripEnabled = stripCfg.isEnabled
        stripGap = stripCfg.gap
        stripInset = stripCfg.inset
        stripAutoCenter = stripCfg.autoCenterOnApproval
        stripHalos = stripCfg.statusHalosEnabled
        stripHotkeys = stripCfg.hotkeysEnabled
        stripWidthPreset = stripCfg.defaultWidthPreset
        stripSpringOmega = stripCfg.springOmega
        stripDimInactive = stripCfg.dimInactive
        stripChevrons = stripCfg.showNavigationChevrons
        stripIndicator = stripCfg.showStripIndicator
        stripKeepHeight = stripCfg.keepOriginalHeight
        stripFloatFixed = stripCfg.floatFixedSizeWindows
        stripFloatStubborn = stripCfg.floatStubbornWindows
        stripDisabledDisplays = stripCfg.disabledDisplayKeys
        desktopHUDPinned = DesktopHUDController.shared.isPinned
        openCodeGoAllowanceUSD = NotchHUDConfig.shared.openCodeGoAllowanceUSD
        hotkeyApprove = NotchHUDConfig.shared.globalHotkeyApproveEnabled
        hotkeyDeny = NotchHUDConfig.shared.globalHotkeyDenyEnabled
        hotkeySnooze = NotchHUDConfig.shared.globalHotkeySnoozeEnabled
        quotaBadgeThreshold = NotchHUDConfig.shared.quotaBadgeThresholdPercent
        desktopHUDAutoHide = NotchHUDConfig.shared.desktopHUDAutoHideSeconds
        hasAccessibility = StripWindowRegistry.hasAccessibilityPermission()
        DispatchQueue.main.async {
            isRefreshingConfig = false
        }
        // `launchctl print` is slow; probe off the main thread so opening
        // Settings can never beachball.
        Task.detached(priority: .utility) {
            let loaded = LaunchAgent.isLoaded()
            await MainActor.run {
                if launchAtLogin != loaded {
                    isRefreshingConfig = true
                    launchAtLogin = loaded
                    DispatchQueue.main.async {
                        isRefreshingConfig = false
                    }
                }
            }
        }
    }

    /// One row per display, keyed by the stable display id.
    private var displayOptions: [(key: String, name: String)] {
        NSScreen.screens.map {
            (key: StripDisplayPlanner.displayKey(for: $0), name: $0.localizedName)
        }
    }

    private func updateStripConfig() {
        var cfg = StripConfiguration.load()
        cfg.isEnabled = stripEnabled
        cfg.gap = stripGap
        cfg.inset = stripInset
        cfg.autoCenterOnApproval = stripAutoCenter
        cfg.statusHalosEnabled = stripHalos
        cfg.hotkeysEnabled = stripHotkeys
        cfg.defaultWidthPreset = stripWidthPreset
        cfg.springOmega = stripSpringOmega
        cfg.dimInactive = stripDimInactive
        cfg.showNavigationChevrons = stripChevrons
        cfg.showStripIndicator = stripIndicator
        cfg.keepOriginalHeight = stripKeepHeight
        cfg.floatFixedSizeWindows = stripFloatFixed
        cfg.floatStubbornWindows = stripFloatStubborn
        cfg.disabledDisplayKeys = stripDisabledDisplays
        cfg.save()
        StripWindowManager.shared.config = cfg
    }

    private func terminalLabel(_ bundleID: String) -> String {
        switch bundleID {
        case "com.ghostty.app": return "Ghostty"
        case "dev.warp.Warp-Stable": return "Warp"
        case "org.wezfurlong.wezterm": return "WezTerm"
        case "io.alacritty": return "Alacritty"
        case "com.googlecode.iterm2": return "iTerm2"
        case "com.apple.Terminal": return "Terminal"
        case "com.microsoft.VSCode": return "VS Code"
        case "com.microsoft.VSCodeInsiders": return "VS Code Insiders"
        case "com.jetbrains.intellij": return "IntelliJ IDEA"
        default: return bundleID
        }
    }

    /// Plays the access-request alert at the current volume: immediate
    /// confirmation when enabling sounds, and (debounced) while scrubbing
    /// the volume stepper so the user hears what they are setting.
    private func playAlertSample() {
        let sound = NSSound(named: AgentEventKind.accessRequest.soundName)
        sound?.volume = NotchHUDConfig.shared.soundVolume
        sound?.play()
    }

    private func previewAlertVolume() {
        volumePreviewTask?.cancel()
        volumePreviewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            playAlertSample()
        }
    }

    private func timeLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// Where the app-managed herdr plugin manifest lives.
    private static var herdrManifestPath: String {
        LaunchAgent.dataDirectory() + "/" + HerdrPluginInstaller.manifestFileName
    }

    /// One-click herdr integration: write adapter + manifest, then register
    /// with the running herdr server over its socket. Best-effort — herdr
    /// not running just means events start at next launch.
    private func installHerdrPlugin() {
        let dataDir = LaunchAgent.dataDirectory()
        let manifest = Self.herdrManifestPath
        guard HerdrPluginInstaller.install(dataDir: dataDir, manifestPath: manifest) else {
            herdrPluginInstalled = false
            let alert = NSAlert()
            alert.messageText = "Could not install the herdr integration"
            alert.informativeText =
                "The event adapter could not be written to the app data folder."
            alert.runModal()
            return
        }
        Task {
            let path = HerdrSocketProtocol.socketPath(
                env: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
            let client = HerdrSocketClient(socketURL: URL(fileURLWithPath: path))
            let params = "{\"path\": \"\(manifest)\", \"enabled\": true}"
            _ = await client.call(method: "plugin.link", paramsJSON: params)
        }
    }

    private func uninstallHerdrPlugin() {
        Task {
            let path = HerdrSocketProtocol.socketPath(
                env: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
            let client = HerdrSocketClient(socketURL: URL(fileURLWithPath: path))
            let params = "{\"plugin_id\": \"\(HerdrPluginInstaller.pluginID)\"}"
            _ = await client.call(method: "plugin.unlink", paramsJSON: params)
            HerdrPluginInstaller.uninstall(manifestPath: Self.herdrManifestPath)
        }
    }

    /// Install or remove the Claude Code hooks in ~/.claude/settings.json.
    /// On write failure — or when the existing file exists but cannot be
    /// parsed — the toggle reverts and the user is told why. Bantay never
    /// writes over a settings.json it failed to read.
    private func installClaudeHook(_ enabled: Bool) {
        let home = NSHomeDirectory()
        let settingsPath = home + "/.claude/settings.json"
        let settingsURL = URL(fileURLWithPath: settingsPath)
        let fileExists = FileManager.default.fileExists(atPath: settingsPath)
        var parsed = false
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            settings = obj
            parsed = true
        }
        let merged =
            enabled
            ? ClaudeHookInstaller.mergedSettings(
                existing: settings, port: NotchHUDConfig.shared.ingestPort,
                token: NotchHUDConfig.shared.ingestToken)
            : ClaudeHookInstaller.removingBantayHooks(from: settings)
        switch ClaudeHookWriteDecision.decide(
            fileExists: fileExists, parsed: parsed, merged: merged)
        {
        case .abort:
            claudeHookRevertFailure(
                enabled,
                reason:
                    "~/.claude/settings.json exists but could not be read as JSON. "
                    + "Bantay never overwrites a file it cannot parse — fix the file "
                    + "or remove it and try again.")
            return
        case .write(let payload):
            guard
                let data = try? JSONSerialization.data(
                    withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            else {
                claudeHookRevertFailure(enabled)
                return
            }
            do {
                // Atomic write: `.atomic` writes to a temp file in the same
                // directory and renames over the target, so a crash or a
                // concurrent Claude Code process can never leave a truncated/
                // interleaved settings.json.
                try data.write(to: settingsURL, options: [.atomic])
                // Preserve the existing file's permissions (or default to 600
                // on a fresh install) — settings.json is user-private.
                let current =
                    try? FileManager.default.attributesOfItem(
                        atPath: settingsURL.path)[.posixPermissions] as? NSNumber
                let perms = current ?? NSNumber(value: 0o600)
                try FileManager.default.setAttributes(
                    [.posixPermissions: perms], ofItemAtPath: settingsURL.path)
            } catch {
                claudeHookRevertFailure(enabled)
                AppDelegate.dbg(
                    "claude hook: could not write \(settingsPath): \(error)")
                return
            }
        }
        if enabled {
            NotchHUDConfig.shared.ingestEnabled = true
            AppDelegate.shared?.updateIngestServer()
        }
        NotchHUDConfig.shared.claudeHookInstalled = enabled
        claudeHookInstalled = enabled
    }

    private func claudeHookRevertFailure(
        _ enabled: Bool,
        reason: String = "Failed to write ~/.claude/settings.json. Check permissions and try again."
    ) {
        claudeHookInstalled = !enabled
        NotchHUDConfig.shared.claudeHookInstalled = !enabled
        let alert = NSAlert()
        alert.messageText = "Could not \(enabled ? "install" : "remove") the Claude Code hook"
        alert.informativeText = reason
        alert.runModal()
    }
}

struct WelcomeView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    /// `launchctl print` is slow (and can block seconds on the GUI domain),
    /// so probe it off the main thread and default to off until it resolves —
    /// a beachball on the welcome screen is a non-starter.
    @State private var launchAtLogin = false
    @State private var isRefreshingConfig = false
    @State private var hideAtStartup = NotchHUDConfig.shared.hideAtStartup
    @State private var hasAccessibility = StripWindowRegistry.hasAccessibilityPermission()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Bantay-TUI")
                .font(.headline)
            Text(
                "The pill under your notch shows what your AI agents are doing: "
                    + "work in progress, approvals waiting on you, and "
                    + "completions — without you hunting through panes.")
            Text(
                "Install the herdr hook once with `scripts/setup.sh`, and the "
                    + "island feeds live agent events.")
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    guard !isRefreshingConfig else { return }
                    LaunchAgent.setLaunchAtLogin(newValue)
                }
            Toggle("Hide island at startup", isOn: $hideAtStartup)
                .onChange(of: hideAtStartup) { newValue in
                    NotchHUDConfig.shared.hideAtStartup = newValue
                }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(
                        systemName: hasAccessibility
                            ? "checkmark.circle.fill" : "circle.dashed"
                    )
                    .foregroundColor(hasAccessibility ? .green : .secondary)
                    Text(
                        hasAccessibility
                            ? "Accessibility granted"
                            : "Accessibility (optional)"
                    )
                    .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !hasAccessibility {
                        Button("Grant…") {
                            StripWindowRegistry.promptAccessibilityPermission()
                            StripWindowRegistry.openAccessibilitySettings()
                            hasAccessibility =
                                StripWindowRegistry.hasAccessibilityPermission()
                        }
                        Button("Check again") {
                            hasAccessibility =
                                StripWindowRegistry.hasAccessibilityPermission()
                        }
                        .buttonStyle(.link)
                    }
                }
                Text(
                    hasAccessibility
                        ? "Bantay can focus terminals, type into apps, and move the Desktop strip."
                        : "Lets Bantay focus terminals, type into apps, and move the Desktop strip. The notch inbox and pane approvals work without it."
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
            HStack {
                Spacer()
                Button("Done") {
                    hasSeenOnboarding = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
        .preferredColorScheme(.dark)
        .background(BantayTheme.deepBackground)
        .onAppear {
            Task.detached(priority: .utility) {
                let loaded = LaunchAgent.isLoaded()
                await MainActor.run {
                    if launchAtLogin != loaded {
                        isRefreshingConfig = true
                        launchAtLogin = loaded
                        DispatchQueue.main.async {
                            isRefreshingConfig = false
                        }
                    }
                }
            }
        }
    }
}
