import Foundation

/// Installs `bantay-opencode.js` into openCode's global plugin directory so
/// openCode sessions flow into Bantay's event pipeline (working / needs
/// approval / done / failed) the same way herdr-managed agents do. The plugin
/// is a no-op when Bantay is absent, so enabling it is safe even if the user
/// only sometimes runs openCode.
enum OpenCodePluginInstaller {
    static let pluginFilename = "bantay-opencode.js"

    /// openCode's global plugin dir (openCode loads every .js/.ts here at
    /// startup).
    static func pluginDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/opencode/plugins", isDirectory: true)
    }

    static func pluginURL() -> URL {
        pluginDirectory().appendingPathComponent(pluginFilename, isDirectory: false)
    }

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: pluginURL().path)
    }

    /// Copy the bundled plugin into openCode's plugin dir. Returns an error
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
        do {
            try FileManager.default.createDirectory(
                at: pluginDirectory(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: pluginURL().path) {
                try FileManager.default.removeItem(at: pluginURL())
            }
            try FileManager.default.copyItem(at: source, to: pluginURL())
            return nil
        } catch {
            return "install failed: \(error.localizedDescription)"
        }
    }

    /// Remove the plugin. Returns an error message on failure (nil on
    /// success, including when it wasn't installed).
    static func remove() -> String? {
        guard isInstalled() else { return nil }
        do {
            try FileManager.default.removeItem(at: pluginURL())
            return nil
        } catch {
            return "remove failed: \(error.localizedDescription)"
        }
    }
}
