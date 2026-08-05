import SwiftUI
import UserNotifications

struct SettingsView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    @State private var captureEnabled = NotchHUDConfig.shared.captureEnabled
    @State private var captureInterval = Int(NotchHUDConfig.shared.captureInterval)
    @State private var enableAlerts = NotchHUDConfig.shared.enableAgentAlerts
    @State private var soundVolume = Int(NotchHUDConfig.shared.soundVolume * 100)
    @State private var autoClearTTL = Int(NotchHUDConfig.shared.autoClearTTL)
    @State private var stickyTTL = Int(NotchHUDConfig.shared.stickyApprovalTTL)
    @State private var launchAtLogin = LaunchAgent.isLoaded()
    @State private var hideAtStartup = NotchHUDConfig.shared.hideAtStartup
    @State private var showIslandWhenIdle = NotchHUDConfig.shared.showIslandWhenIdle
    @State private var muteInTerminal = NotchHUDConfig.shared.muteInTerminal
    @State private var dockSide = NotchHUDConfig.shared.islandDockSide.rawValue
    @State private var idleStyle = NotchHUDConfig.shared.idleStyle.rawValue
    @State private var idleMaxChips = NotchHUDConfig.shared.clampedIdleMaxChips
    @State private var expandedQueueCap = NotchHUDConfig.shared.clampedExpandedQueueCap
    @State private var expandedShowQueue = NotchHUDConfig.shared.expandedShowQueue
    @State private var expandedGroupByState = NotchHUDConfig.shared.expandedGroupByState
    @State private var hotkeyEnabled = NotchHUDConfig.shared.globalHotkeyEnabled
    @State private var keyboardShortcuts = NotchHUDConfig.shared.keyboardShortcuts
    @State private var edgeGlow = NotchHUDConfig.shared.edgeGlowEnabled
    @State private var showElapsed = NotchHUDConfig.shared.showElapsedTime
    @State private var menuBadge = NotchHUDConfig.shared.menuBarBadge
    @State private var standaloneScan = NotchHUDConfig.shared.standaloneScanEnabled
    @State private var showUsage = NotchHUDConfig.shared.showUsageGauge
    @State private var usageBudget = Int(NotchHUDConfig.shared.usageBudgetUSD)
    @State private var ingestEnabled = NotchHUDConfig.shared.ingestEnabled
    @State private var ingestPort = NotchHUDConfig.shared.ingestPort
    @State private var showShelf = NotchHUDConfig.shared.showShelfTab
    @State private var shelfLimit = NotchHUDConfig.shared.clampedShelfLimit
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
    @State private var attentionFilter = NotchHUDConfig.shared.attentionFilterEnabled
    @State private var volumePreviewTask: Task<Void, Never>?
    @State private var herdrPluginInstalled = HerdrPluginInstaller.isInstalled(
        manifestPath: Self.herdrManifestPath)

    var body: some View {
        Form {
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
                Toggle("Usage gauge in footer", isOn: $showUsage)
                    .help("Token/cost bar from agent transcripts.")
                    .onChange(of: showUsage) { newValue in
                        NotchHUDConfig.shared.showUsageGauge = newValue
                    }
                Stepper("Usage budget: $\(usageBudget)", value: $usageBudget, in: 1...100)
                    .help("Gauge turns amber at 70%, red at 90% of budget.")
                    .onChange(of: usageBudget) { newValue in
                        NotchHUDConfig.shared.usageBudgetUSD = Double(newValue)
                    }
            }
            Section("Muted sources") {
                if mutedSources.isEmpty {
                    Text("Nothing muted — right-click an agent row and pick Mute to hide a source.")
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
            Section("Shelf") {
                Toggle("Shelf tab in expanded view", isOn: $showShelf)
                    .help("Clipboard history + dropped files next to agents.")
                    .onChange(of: showShelf) { newValue in
                        NotchHUDConfig.shared.showShelfTab = newValue
                    }
                Stepper("Shelf limit: \(shelfLimit)", value: $shelfLimit, in: 1...50)
                    .onChange(of: shelfLimit) { newValue in
                        NotchHUDConfig.shared.shelfLimit = newValue
                    }
            }
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
                    Button("Send test notification") {
                        AgentEventManager.shared.publishForTesting()
                    }
                #else
                    Text("Test notification is available in debug builds only.")
                #endif
            }
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
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .help("Runs the app at login; installs the launch agent on first enable.")
                    .onChange(of: launchAtLogin) { newValue in
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
                        IslandMetrics.IslandDockSide(rawValue: newValue) ?? .right
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
            Section("Expanded panel") {
                Toggle("Attention-only tab", isOn: $attentionFilter)
                    .help(
                        "Adds an Attention tab showing only agents that need "
                            + "you or failed — the 'everything that needs me' triage."
                    )
                    .onChange(of: attentionFilter) { newValue in
                        NotchHUDConfig.shared.attentionFilterEnabled = newValue
                    }
                Toggle("Pin approval queue on top", isOn: $expandedShowQueue)
                    .help("Blocked agents get approve/deny cards above the roster.")
                    .onChange(of: expandedShowQueue) { newValue in
                        NotchHUDConfig.shared.expandedShowQueue = newValue
                    }
                Toggle("Group agents by state", isOn: $expandedGroupByState)
                    .help("Need-input first, then working, done, failed, idle.")
                    .onChange(of: expandedGroupByState) { newValue in
                        NotchHUDConfig.shared.expandedGroupByState = newValue
                    }
                Stepper(
                    "Approval queue cards: \(expandedQueueCap)",
                    value: $expandedQueueCap, in: 1...5
                )
                .help("Extra blocked agents collapse into '+N more'.")
                .onChange(of: expandedQueueCap) { newValue in
                    NotchHUDConfig.shared.expandedQueueCap = newValue
                }
            }
            Section("Quick actions") {
                Toggle("Global shortcut ⌥Space", isOn: $hotkeyEnabled)
                    .help("Show/hide the island from any app.")
                    .onChange(of: hotkeyEnabled) { newValue in
                        NotchHUDConfig.shared.globalHotkeyEnabled = newValue
                        AppDelegate.shared?.updateGlobalHotkeyMonitor()
                    }
                Toggle("Keyboard shortcuts in roster", isOn: $keyboardShortcuts)
                    .help("With the island focused: Y approve, N deny, 1-9 choose.")
                    .onChange(of: keyboardShortcuts) { newValue in
                        NotchHUDConfig.shared.keyboardShortcuts = newValue
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
            Section {
                Button("Show Welcome…") {
                    hasSeenOnboarding = false
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 860)
        .onAppear { refreshFromConfig() }
        .onReceive(NotificationCenter.default.publisher(for: .settingsWillOpen)) { _ in
            refreshFromConfig()
        }
    }

    /// Re-read externally mutable state (menu-bar toggles, launch agent
    /// status, hook installs) so a persisted Settings window never shows
    /// stale toggles.
    private func refreshFromConfig() {
        captureEnabled = NotchHUDConfig.shared.captureEnabled
        enableAlerts = NotchHUDConfig.shared.enableAgentAlerts
        notifyWhenHidden = NotchHUDConfig.shared.notifyWhenHidden
        quietHoursEnabled = NotchHUDConfig.shared.quietHoursEnabled
        mutedSources = NotchHUDConfig.shared.mutedSources
        claudeHookInstalled = NotchHUDConfig.shared.claudeHookInstalled
        herdrPluginInstalled = HerdrPluginInstaller.isInstalled(
            manifestPath: Self.herdrManifestPath)
        launchAtLogin = LaunchAgent.isLoaded()
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
    @State private var launchAtLogin = LaunchAgent.isLoaded()
    @State private var hideAtStartup = NotchHUDConfig.shared.hideAtStartup
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
                    LaunchAgent.setLaunchAtLogin(newValue)
                }
            Toggle("Hide island at startup", isOn: $hideAtStartup)
                .onChange(of: hideAtStartup) { newValue in
                    NotchHUDConfig.shared.hideAtStartup = newValue
                }
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
    }
}
