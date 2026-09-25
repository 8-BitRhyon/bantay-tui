import AppKit
import Foundation

/// Terminal bundle IDs ordered by user activation preference.
enum TerminalRegistry {
    static let preferredBundleIDs: [String] = [
        "com.ghostty.app",
        "dev.warp.Warp-Stable",
        "org.wezfurlong.wezterm",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "com.anysphere.cursor",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "dev.zed.Zed",
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
        app.activate(options: [.activateIgnoringOtherApps])
        NSApp?.deactivate()
        return true
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

    /// Focus a standalone application window (e.g. Antigravity IDE, Cursor, Windsurf) by workspace path or app bundle.
    @MainActor
    @discardableResult
    static func focusStandalone(source: String, cwd: String? = nil) -> Bool {
        let nameLower = source.lowercased()
        let runningApps = NSWorkspace.shared.runningApplications
        let targetApp = runningApps.first { app in
            let appName = (app.localizedName ?? "").lowercased()
            let bundleID = (app.bundleIdentifier ?? "").lowercased()
            if nameLower == "antigravity" || nameLower == "antigravity-ide"
                || nameLower == "agy"
            {
                return appName.contains("antigravity") || appName.contains("agy")
                    || bundleID.contains("antigravity") || bundleID.contains("agy")
            }
            if nameLower == "cursor" {
                return appName.contains("cursor") || bundleID.contains("cursor")
                    || bundleID == "com.anysphere.cursor"
                    || bundleID == "com.todesktop.230313mzl4w4u92"
            }
            if nameLower == "windsurf" || nameLower == "cascade" {
                return appName.contains("windsurf") || appName.contains("cascade")
                    || bundleID.contains("windsurf") || bundleID.contains("cascade")
            }
            if nameLower == "cloudcode" || nameLower == "cloud-code" {
                return appName.contains("cloudcode") || appName.contains("cloud code")
                    || bundleID.contains("cloudcode")
            }
            if nameLower == "zed" {
                return appName.contains("zed") || bundleID.contains("zed")
            }
            if nameLower == "cline" || nameLower == "roo-code" || nameLower == "continue" {
                return appName.contains("code") || appName.contains("cursor")
                    || appName.contains("windsurf") || bundleID.contains("code")
            }
            if nameLower == "codex" {
                return appName.contains("codex") || bundleID.contains("codex")
            }
            if nameLower == "gemini" {
                return appName.contains("gemini") || bundleID.contains("gemini")
            }
            return appName == nameLower || appName.contains(nameLower)
                || bundleID == nameLower || bundleID.contains(nameLower)
        }

        if let app = targetApp {
            app.activate(options: [.activateIgnoringOtherApps])
            NSApp?.deactivate()
            if let bundleID = app.bundleIdentifier {
                let script = "tell application id \"\(bundleID)\" to activate"
                if let asObj = NSAppleScript(source: script) {
                    var err: NSDictionary?
                    asObj.executeAndReturnError(&err)
                }
            }
            return true
        }

        // If target GUI app isn't currently running, launch it directly if installed
        if nameLower == "cursor" {
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.anysphere.cursor")
                ?? NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.todesktop.230313mzl4w4u92")
            {
                return NSWorkspace.shared.open(url)
            }
        } else if nameLower == "windsurf" || nameLower == "cascade" {
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.exafunction.windsurf")
            {
                return NSWorkspace.shared.open(url)
            }
        }

        return focus(preferredBundleID: NotchHUDConfig.shared.preferredTerminalBundleID)
    }
}
