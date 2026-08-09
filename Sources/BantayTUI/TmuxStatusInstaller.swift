import Foundation

/// Installs/removes the `#(bantay-status)` tmux status-bar interpolation so
/// agent status shows inside the terminal you're already using, not just on
/// the notch. The helper script ships to `~/Library/Application Support/
/// Bantay-TUI/bantay-status.sh` by `scripts/setup.sh`; this wires it into
/// the running tmux session's `status-right` (and any future sessions via
/// `-g`), preserving whatever was there before so removal can restore it.
enum TmuxStatusInstaller {
    /// The status-right fragment we manage, wrapped so we can find it again.
    static func statusFragment() -> String {
        "#(bantay-status)"
    }

    /// Absolute path to the shipped helper script (setup.sh installs it
    /// beside the app binary in Application Support).
    static func scriptPath() -> String {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bantay-TUI/bantay-status.sh", isDirectory: false)
            .path
    }

    static func statusCommand(scriptPath: String) -> String {
        // Quote the path so Application Support paths with spaces survive
        // tmux's `#()` shell interpolation.
        "#(\"\(scriptPath)\")"
    }

    /// Wire bantay-status into tmux `status-right`. Returns nil on success,
    /// or an error message when tmux is unavailable.
    static func install(scriptPath: String) -> String? {
        guard executableExists("tmux") else {
            return "tmux not found on PATH"
        }
        let fragment = statusCommand(scriptPath: scriptPath)
        let current = tmuxShowOption("status-right") ?? ""
        if current.contains(fragment) {
            return nil
        }
        let merged = current.isEmpty ? fragment : "\(current) · \(fragment)"
        return tmuxSetOption("status-right", merged)
    }

    /// Remove our fragment from `status-right`, restoring the prior value.
    static func remove(scriptPath: String) -> String? {
        guard executableExists("tmux") else { return nil }
        let fragment = statusCommand(scriptPath: scriptPath)
        let current = tmuxShowOption("status-right") ?? ""
        guard current.contains(fragment) else { return nil }
        let stripped =
            current
            .replacingOccurrences(of: " · \(fragment)", with: "")
            .replacingOccurrences(of: fragment, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tmuxSetOption("status-right", stripped)
    }

    static func isInstalled(scriptPath: String) -> Bool {
        let fragment = statusCommand(scriptPath: scriptPath)
        return (tmuxShowOption("status-right") ?? "").contains(fragment)
    }

    private static func executableExists(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-lc", "command -v \(name) >/dev/null 2>&1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func tmuxShowOption(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "show-option", "-g", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            // Output: "status-right \"...\""
            let line = String(data: data, encoding: .utf8) ?? ""
            let components = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard components.count == 2 else { return nil }
            return components[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"\n "))
        } catch {
            return nil
        }
    }

    private static func tmuxSetOption(_ name: String, _ value: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "set-option", "-g", name, value]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? nil : "tmux set-option failed"
        } catch {
            return "tmux unavailable"
        }
    }
}
