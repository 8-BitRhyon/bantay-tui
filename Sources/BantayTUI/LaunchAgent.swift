import Foundation

/// Façade over the launchd agent that `scripts/setup.sh` installs
/// (label `com.bantay-tui.agent`, plist in `~/Library/LaunchAgents`).
enum LaunchAgent {
    static let label = "com.bantay-tui.agent"

    /// Process-wide test seams; not actually shared across threads in use.
    nonisolated(unsafe) static var plistPath: String =
        NSHomeDirectory() + "/Library/LaunchAgents/com.bantay-tui.agent.plist"

    /// Injectable for tests; defaults to the real `launchctl` CLI.
    nonisolated(unsafe) static var processRunner: ([String]) -> Int32 = { args in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// True when launchd has the agent bootstrapped in the user's GUI domain.
    static func isLoaded() -> Bool {
        processRunner(["print", "gui/\(getuid())/\(label)"]) == 0
    }

    /// Enables/disables start-at-login. Enabling requires the agent plist from
    /// `scripts/setup.sh`; disabling boots the agent out and removes the plist.
    static func setLaunchAtLogin(_ on: Bool) {
        let uid = getuid()
        if on {
            guard isInstalled else { return }
            _ = processRunner(["bootstrap", "gui/\(uid)", plistPath])
        } else {
            _ = processRunner(["bootout", "gui/\(uid)/\(label)"])
            try? FileManager.default.removeItem(atPath: plistPath)
        }
    }
}
