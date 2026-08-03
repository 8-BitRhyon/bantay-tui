import AppKit
import Foundation

/// Terminal-emulator bundle IDs, ordered by preference. The focus helper
/// activates whichever of these is running instead of hardcoding Apple
/// Terminal or iTerm2 — so Ghostty, Warp, WezTerm, Alacritty, and even
/// VSCode's integrated terminal all work.
enum TerminalRegistry {
    static let preferredBundleIDs: [String] = [
        "com.ghostty.app",
        "dev.warp.Warp-Stable",
        "org.wezfurlong.wezterm",
        "io.alacritty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.jetbrains.intellij",
    ]

    /// The first preferred terminal that is currently running, or nil.
    static func runningTerminal(
        runningBundleIDs: [String], preferred: String? = nil
    ) -> String? {
        let running = Set(runningBundleIDs)
        if let preferred, running.contains(preferred) {
            return preferred
        }
        return preferredBundleIDs.first { running.contains($0) }
    }
}

/// Activates the terminal app hosting the agent's pane. Falls back through
/// the registry; if nothing is running, opens the system Terminal.
enum TerminalFocusser {
    @MainActor
    static func focus(
        preferredBundleID: String? = nil
    ) -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        let runningIDs = runningApps.compactMap(\.bundleIdentifier)
        guard
            let target = TerminalRegistry.runningTerminal(
                runningBundleIDs: runningIDs, preferred: preferredBundleID)
        else {
            return openSystemTerminal()
        }
        guard let app = runningApps.first(where: { $0.bundleIdentifier == target }) else {
            return openSystemTerminal()
        }
        return app.activate(options: [.activateAllWindows])
    }

    @MainActor
    private static func openSystemTerminal() -> Bool {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Terminal")
        else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
