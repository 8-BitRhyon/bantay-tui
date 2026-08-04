import Foundation

/// Façade over the launchd agent that `scripts/setup.sh` installs
/// (label `com.bantay-tui.agent`, plist in `~/Library/LaunchAgents`).
/// The app can also install and manage the agent itself, so distributed
/// users get working "Launch at login" without ever running a script.
enum LaunchAgent {
    static let label = "com.bantay-tui.agent"
    static let eventsFileName = "agent-events.jsonl"

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

    /// Binary the launch agent runs. Defaults to the running app's own
    /// executable so a distributed .app manages itself; injectable for tests.
    nonisolated(unsafe) static var defaultBinaryPath: String =
        Bundle.main.executablePath ?? ""

    /// The per-user data directory (mirrors `scripts/setup.sh` DATA_DIR).
    static func dataDirectory(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/Bantay-TUI"
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// True when launchd has the agent bootstrapped in the user's GUI domain.
    static func isLoaded() -> Bool {
        processRunner(["print", "gui/\(getuid())/\(label)"]) == 0
    }

    /// Plist content mirroring `scripts/setup.sh`, with the app's own binary.
    static func plistContent(binaryPath: String, dataDir: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(dataDir)/bantay.log</string>
            <key>StandardErrorPath</key>
            <string>\(dataDir)/bantay.err</string>
        </dict>
        </plist>
        """
    }

    /// Creates the data directory and touches the events file
    /// (setup.sh parity). Idempotent; safe to call at every launch.
    @discardableResult
    static func ensureDataDirectory(dataDir: String = dataDirectory()) -> Bool {
        guard !dataDir.isEmpty else { return false }
        try? FileManager.default.createDirectory(
            atPath: dataDir, withIntermediateDirectories: true)
        let eventsFile = dataDir + "/" + eventsFileName
        if !FileManager.default.fileExists(atPath: eventsFile) {
            FileManager.default.createFile(atPath: eventsFile, contents: nil)
        }
        return FileManager.default.fileExists(atPath: eventsFile)
    }

    /// Full install: data dir + events file, agent plist pointing at the
    /// given binary, then (re)load the agent. Idempotent.
    /// Returns false (and leaves launchd untouched) when the plist could not
    /// be written; when it was written, reports whether the agent actually
    /// loaded.
    @discardableResult
    static func install(
        binaryPath: String = defaultBinaryPath,
        dataDir: String = dataDirectory()
    ) -> Bool {
        guard !binaryPath.isEmpty else { return false }
        guard ensureDataDirectory(dataDir: dataDir) else {
            NSLog("bantay: launch agent data dir could not be created")
            return false
        }
        let content = plistContent(binaryPath: binaryPath, dataDir: dataDir)
        do {
            try content.write(toFile: plistPath, atomically: true, encoding: .utf8)
        } catch {
            NSLog("bantay: could not write launch agent plist: \(error)")
            return false
        }
        let uid = getuid()
        _ = processRunner(["bootout", "gui/\(uid)/\(label)"])
        if processRunner(["bootstrap", "gui/\(uid)", plistPath]) != 0 {
            _ = processRunner(["load", plistPath])
        }
        let loaded = isLoaded()
        if !loaded {
            NSLog("bantay: launch agent not loaded after install")
        }
        return loaded
    }

    /// Enables/disables start-at-login. Enabling self-installs the agent
    /// plist (pointing at the running app) when nothing is installed yet;
    /// disabling boots the agent out and removes the plist.
    /// Returns whether the requested state was reached.
    @discardableResult
    static func setLaunchAtLogin(_ on: Bool) -> Bool {
        if on {
            let installed = install()
            if !installed {
                NSLog("bantay: launch at login could not be enabled")
            }
            return installed
        } else {
            let uid = getuid()
            _ = processRunner(["bootout", "gui/\(uid)/\(label)"])
            do {
                try FileManager.default.removeItem(atPath: plistPath)
            } catch {
                NSLog("bantay: could not remove launch agent plist: \(error)")
            }
            return true
        }
    }
}
