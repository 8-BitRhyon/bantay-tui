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
            }
            Section {
                Button("Show Welcome…") {
                    hasSeenOnboarding = false
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
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
