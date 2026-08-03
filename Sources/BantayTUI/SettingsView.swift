import SwiftUI

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
    @State private var muteInTerminal = NotchHUDConfig.shared.muteInTerminal
    @State private var dockSide = NotchHUDConfig.shared.islandDockSide.rawValue
    @State private var idleStyle = NotchHUDConfig.shared.idleStyle.rawValue
    @State private var idleMaxChips = NotchHUDConfig.shared.clampedIdleMaxChips
    @State private var expandedQueueCap = NotchHUDConfig.shared.clampedExpandedQueueCap
    @State private var expandedShowQueue = NotchHUDConfig.shared.expandedShowQueue
    @State private var expandedGroupByState = NotchHUDConfig.shared.expandedGroupByState

    var body: some View {
        Form {
            Section("Capture") {
                Toggle("Poll agents", isOn: $captureEnabled)
                    .onChange(of: captureEnabled) { _, newValue in
                        NotchHUDConfig.shared.captureEnabled = newValue
                    }
                Stepper(
                    "Poll interval: \(captureInterval) s",
                    value: $captureInterval, in: 1...60
                )
                .onChange(of: captureInterval) { _, newValue in
                    NotchHUDConfig.shared.captureInterval = Double(newValue)
                }
            }
            Section("Alerts") {
                Toggle("Alert sounds", isOn: $enableAlerts)
                    .onChange(of: enableAlerts) { _, newValue in
                        NotchHUDConfig.shared.enableAgentAlerts = newValue
                    }
                Stepper(
                    "Volume: \(soundVolume)%",
                    value: $soundVolume, in: 0...100, step: 5
                )
                .onChange(of: soundVolume) { _, newValue in
                    NotchHUDConfig.shared.soundVolume = Float(newValue) / 100
                }
                Toggle("Mute while in Terminal", isOn: $muteInTerminal)
                    .onChange(of: muteInTerminal) { _, newValue in
                        NotchHUDConfig.shared.muteInTerminal = newValue
                    }
                #if DEBUG
                    Button("Send test notification") {
                        AgentEventManager.shared.publishForTesting()
                    }
                #else
                    Text("Test notification is available in debug builds only.")
                #endif
            }
            Section("Pill behavior") {
                Stepper("Auto-clear after \(autoClearTTL) s", value: $autoClearTTL, in: 1...30)
                    .onChange(of: autoClearTTL) { _, newValue in
                        NotchHUDConfig.shared.autoClearTTL = Double(newValue)
                    }
                Stepper(
                    "Sticky approvals for \(stickyTTL) s",
                    value: $stickyTTL, in: 10...120, step: 5
                )
                .onChange(of: stickyTTL) { _, newValue in
                    NotchHUDConfig.shared.stickyApprovalTTL = Double(newValue)
                }
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .help("Requires the launch agent installed by scripts/setup.sh.")
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAgent.setLaunchAtLogin(newValue)
                    }
                Toggle("Hide island at startup", isOn: $hideAtStartup)
                    .help(
                        "Keep the island hidden after launch until an approval "
                            + "needs your attention (or you interact once)."
                    )
                    .onChange(of: hideAtStartup) { _, newValue in
                        NotchHUDConfig.shared.hideAtStartup = newValue
                    }
                Picker("Idle position", selection: $dockSide) {
                    Text("Right of notch").tag("right")
                    Text("Left of notch").tag("left")
                    Text("Center").tag("center")
                }
                .onChange(of: dockSide) { _, newValue in
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
                .onChange(of: idleStyle) { _, newValue in
                    NotchHUDConfig.shared.idleStyle =
                        IslandMetrics.IdleStyle(rawValue: newValue) ?? .names
                    NotificationCenter.default.post(
                        name: .notchVisibilityChanged, object: nil)
                }
                Stepper("Max agent chips: \(idleMaxChips)", value: $idleMaxChips, in: 1...6)
                    .help("Longer strips truncate to +N.")
                    .onChange(of: idleMaxChips) { _, newValue in
                        NotchHUDConfig.shared.idleMaxChips = newValue
                        NotificationCenter.default.post(
                            name: .notchVisibilityChanged, object: nil)
                    }
            }
            Section("Expanded panel") {
                Toggle("Pin approval queue on top", isOn: $expandedShowQueue)
                    .help("Blocked agents get approve/deny cards above the roster.")
                    .onChange(of: expandedShowQueue) { _, newValue in
                        NotchHUDConfig.shared.expandedShowQueue = newValue
                    }
                Toggle("Group agents by state", isOn: $expandedGroupByState)
                    .help("Need-input first, then working, done, failed, idle.")
                    .onChange(of: expandedGroupByState) { _, newValue in
                        NotchHUDConfig.shared.expandedGroupByState = newValue
                    }
                Stepper(
                    "Approval queue cards: \(expandedQueueCap)",
                    value: $expandedQueueCap, in: 1...5
                )
                .help("Extra blocked agents collapse into '+N more'.")
                .onChange(of: expandedQueueCap) { _, newValue in
                    NotchHUDConfig.shared.expandedQueueCap = newValue
                }
            }
            Section {
                Button("Show Welcome…") {
                    hasSeenOnboarding = false
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 700)
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
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAgent.setLaunchAtLogin(newValue)
                }
            Toggle("Hide island at startup", isOn: $hideAtStartup)
                .onChange(of: hideAtStartup) { _, newValue in
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
