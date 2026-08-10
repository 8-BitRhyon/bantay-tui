import Foundation

/// Installs `bantay-opencode.js` into agent plugin directories so sessions
/// flow into Bantay's event pipeline (working / needs approval / done /
/// failed) the same way herdr-managed agents do. The plugin is a no-op when
/// Bantay is absent, so enabling it is safe even if the user only sometimes
/// runs the agent.
///
/// Two targets:
///  - opencode  → `~/.config/opencode/plugins/`  (classic opencode)
///  - kilo      → `~/.config/kilo/plugin/`       (opencode fork — loads the
///    same plugin host from `{plugin,plugins}/*.{ts,js}`; THIS is the path
///    the user's actual agent reads)
enum OpenCodePluginInstaller {
    static let pluginFilename = "bantay-opencode.js"

    /// All directories that load the plugin (opencode + kilo).
    static func targetDirectories() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [
            home.appendingPathComponent(".config/opencode/plugins", isDirectory: true),
            home.appendingPathComponent(".config/kilo/plugin", isDirectory: true),
        ]
    }

    /// openCode's global plugin dir (openCode loads every .js/.ts here at
    /// startup).
    static func pluginDirectory() -> URL {
        targetDirectories()[0]
    }

    static func pluginURL() -> URL {
        pluginDirectory().appendingPathComponent(pluginFilename, isDirectory: false)
    }

    static func isInstalled() -> Bool {
        // Installed if ANY target has the plugin (opencode or kilo).
        targetDirectories().contains { dir in
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(pluginFilename, isDirectory: false).path)
        }
    }

    /// Copy the bundled plugin into every agent plugin dir. Returns an error
    /// message on failure (nil on success). Sources the plugin from the app
    /// support dir (setup.sh copies it beside the binary, like
    /// bantay-status.sh) with a dev fallback to the repo's scripts/ dir.
    static func install() -> String? {
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bantay-TUI", isDirectory: true)
        let installedSource = supportDir.appendingPathComponent(pluginFilename)

        // Dev fallback: this file lives at <repo>/Sources/BantayTUI/, so the
        // plugin is two levels up in scripts/.
        let source =
            FileManager.default.fileExists(atPath: installedSource.path)
            ? installedSource
            : URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("scripts/\(pluginFilename)")

        guard FileManager.default.fileExists(atPath: source.path) else {
            return "openCode plugin source not found (run scripts/setup.sh to install)"
        }
        var lastError: String?
        for dir in targetDirectories() {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(pluginFilename, isDirectory: false)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: source, to: dest)
            } catch {
                lastError =
                    "install failed for \(dir.lastPathComponent): \(error.localizedDescription)"
            }
        }
        return lastError
    }

    /// Remove the plugin from every target. Returns an error message on
    /// failure (nil on success, including when it wasn't installed).
    static func remove() -> String? {
        var lastError: String?
        for dir in targetDirectories() {
            let dest = dir.appendingPathComponent(pluginFilename, isDirectory: false)
            guard FileManager.default.fileExists(atPath: dest.path) else { continue }
            do {
                try FileManager.default.removeItem(at: dest)
            } catch {
                lastError =
                    "remove failed for \(dir.lastPathComponent): \(error.localizedDescription)"
            }
        }
        return lastError
    }
}
