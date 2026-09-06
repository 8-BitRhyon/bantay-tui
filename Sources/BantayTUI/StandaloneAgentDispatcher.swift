import AppKit
import Foundation

public enum StandaloneAgentDispatcher {
    @MainActor
    public static func dispatchPrompt(agentName: String, text: String) {
        // 1. Copy text to pasteboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // 2. Find target running application on macOS
        let running = NSWorkspace.shared.runningApplications
        let targetApp = running.first { app in
            guard let name = app.localizedName?.lowercased() else { return false }
            if agentName == "antigravity" {
                return name.contains("antigravity") || name.contains("agy")
            }
            return name.contains(agentName.lowercased())
        }

        // 4. Activate the target app safely (without blindly typing into open editor windows)
        if let app = targetApp {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }

        // 5. Post notification feedback
        AgentAlertNotifier.notify(
            title: "Prompt Ready for @\(agentName.capitalized)",
            message: "Prompt copied to clipboard. Press ⌘V in chat to send."
        )
    }
}
