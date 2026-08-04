import Foundation

/// Installs the herdr event integration for a *distributed* app: writes the
/// event-adapter script and a plugin manifest (absolute paths, no repo
/// checkout) into the app's data directory, ready for `plugin.link`
/// registration over the herdr socket. Idempotent.
enum HerdrPluginInstaller {
    static let pluginID = "bantay-tui.integration"
    static let manifestFileName = "herdr-plugin.toml"
    static let adapterFileName = "event-adapter.mjs"

    /// The event adapter from `scripts/event-adapter.mjs`, base64-encoded so the
    /// file holds no multiline string literal (swift-format bug). Regenerate:
    ///   base64 -i scripts/event-adapter.mjs | fold -w 96
    /// The L35 drift test fails if this drifts from the repo script.
    static let adapterScript = {
        let b64 =
            "IyEvdXNyL2Jpbi9lbnYgbm9kZQondXNlIHN0cmljdCc7CgppbXBvcnQgZnMgZnJvbSAnbm9kZTpmcyc7CmltcG9ydCBwYXRo"
            + "IGZyb20gJ25vZGU6cGF0aCc7CmltcG9ydCBvcyBmcm9tICdub2RlOm9zJzsKCmNvbnN0IERBVEFfRElSID0gcGF0aC5qb2lu"
            + "KG9zLmhvbWVkaXIoKSwgJ0xpYnJhcnknLCAnQXBwbGljYXRpb24gU3VwcG9ydCcsICdCYW50YXktVFVJJyk7CmNvbnN0IEVW"
            + "RU5UU19GSUxFID0gcGF0aC5qb2luKERBVEFfRElSLCAnYWdlbnQtZXZlbnRzLmpzb25sJyk7Cgpjb25zdCBTVEFUVVNfTUFQ"
            + "ID0gewogIGJsb2NrZWQ6ICdhY2Nlc3NfcmVxdWVzdCcsCiAgZG9uZTogJ2NvbXBsZXRlZCcsCiAgd29ya2luZzogJ3Byb2dy"
            + "ZXNzJywKICBydW5uaW5nOiAnc3RhcnRlZCcsCiAgaWRsZTogJ3dhaXRpbmcnLAogIGZhaWxlZDogJ2ZhaWxlZCcsCiAgY2Fu"
            + "Y2VsbGVkOiAnY2FuY2VsbGVkJywKICBjbGVhcjogJ2NsZWFyJywKfTsKCmNvbnN0IGV2ZW50SnNvbiA9IHByb2Nlc3MuZW52"
            + "LkhFUkRSX1BMVUdJTl9FVkVOVF9KU09OOwppZiAoIWV2ZW50SnNvbikgewogIHByb2Nlc3MuZXhpdCgwKTsKfQoKbGV0IGV2"
            + "ZW50Owp0cnkgewogIGV2ZW50ID0gSlNPTi5wYXJzZShldmVudEpzb24pOwp9IGNhdGNoIHsKICBwcm9jZXNzLmV4aXQoMCk7"
            + "Cn0KCmNvbnN0IGRhdGEgPSBldmVudC5kYXRhOwppZiAoIWRhdGEgfHwgIWRhdGEuYWdlbnRfc3RhdHVzKSB7CiAgcHJvY2Vz"
            + "cy5leGl0KDApOwp9Cgpjb25zdCBzdGF0dXMgPSAoZGF0YS5hZ2VudF9zdGF0dXMgfHwgJycpLnRyaW0oKS50b0xvd2VyQ2Fz"
            + "ZSgpOwpjb25zdCBtYXBwZWQgPSBTVEFUVVNfTUFQW3N0YXR1c107CmlmICghbWFwcGVkKSB7CiAgcHJvY2Vzcy5leGl0KDAp"
            + "Owp9Cgpjb25zdCBzdGF0ZUxhYmVscyA9IGRhdGEuc3RhdGVfbGFiZWxzICYmIHR5cGVvZiBkYXRhLnN0YXRlX2xhYmVscyA9"
            + "PT0gJ29iamVjdCcKICA/IGRhdGEuc3RhdGVfbGFiZWxzCiAgOiBudWxsOwoKLy8gUHJlZmVyIHRoZSBsYWJlbCBmb3IgdGhl"
            + "IGN1cnJlbnQgc3RhdHVzIChyYXcgb3IgbWFwcGVkIGtleSk7IGZhbGwgYmFjayB0bwovLyB0aGUgZmlyc3QgbGFiZWwgb25s"
            + "eSB3aGVuIHRoZSBzdGF0dXMgaGFzIG5vIGVudHJ5Lgpjb25zdCBtZXNzYWdlID0KICAoc3RhdGVMYWJlbHMgJiYgKHN0YXRl"
            + "TGFiZWxzW3N0YXR1c10gfHwgc3RhdGVMYWJlbHNbbWFwcGVkXSkpIHx8CiAgKHN0YXRlTGFiZWxzICYmIE9iamVjdC52YWx1"
            + "ZXMoc3RhdGVMYWJlbHMpWzBdKSB8fAogIGRhdGEuY3VzdG9tX3N0YXR1cyB8fAogIG51bGw7Cgpjb25zdCBwYXlsb2FkID0g"
            + "ewogIHNvdXJjZTogZGF0YS5kaXNwbGF5X2FnZW50IHx8IGRhdGEuYWdlbnQgfHwgJ2hlcmRyJywKICB0eXBlOiBtYXBwZWQs"
            + "CiAgdGl0bGU6IGRhdGEudGl0bGUgfHwgbnVsbCwKICBtZXNzYWdlLAogIHBhbmVJZDogZGF0YS5wYW5lX2lkIHx8IG51bGws"
            + "CiAgd29ya3NwYWNlSWQ6IGRhdGEud29ya3NwYWNlX2lkIHx8IG51bGwsCiAgdmFyaWFuY2U6IGRhdGEudmFyaWFuY2UgfHwg"
            + "bnVsbCwKICBjaG9pY2VzOiBkYXRhLmNob2ljZXMgfHwgZGF0YS5vcHRpb25zIHx8IG51bGwsCn07Cgp0cnkgewogIGZzLm1r"
            + "ZGlyU3luYyhEQVRBX0RJUiwgeyByZWN1cnNpdmU6IHRydWUgfSk7CiAgZnMuYXBwZW5kRmlsZVN5bmMoRVZFTlRTX0ZJTEUs"
            + "IEpTT04uc3RyaW5naWZ5KHBheWxvYWQpICsgJ1xuJywgJ3V0ZjgnKTsKfSBjYXRjaCAoZXJyKSB7CiAgY29uc29sZS5lcnJv"
            + "cignYmFudGF5LXR1aTogZmFpbGVkIHRvIHdyaXRlIGV2ZW50OicsIGVyci5tZXNzYWdlKTsKICBwcm9jZXNzLmV4aXQoMSk7"
            + "Cn0K" + ""
        guard let data = Data(base64Encoded: b64),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }()

    /// Plugin manifest with absolute adapter path. The setup action from the
    /// repo manifest is dropped — the app installs itself, no repo scripts.
    static func manifestContent(dataDir: String) -> String {
        let adapterPath = dataDir + "/" + adapterFileName
        return [
            "id = \"\(pluginID)\"",
            "name = \"Bantay-TUI Integration\"",
            "version = \"0.1.0\"",
            "min_herdr_version = \"0.7.0\"",
            "description = \"Native SwiftUI agent-status display in macOS notch, reading Herdr lifecycle events.\"",
            "platforms = [\"macos\"]",
            "",
            "[[events]]",
            "on = \"pane.agent_status_changed\"",
            "command = [\"node\", \"\(adapterPath)\"]",
        ].joined(separator: "\n")
    }

    /// Whether our manifest is present at the given path.
    static func isInstalled(manifestPath: String) -> Bool {
        FileManager.default.fileExists(atPath: manifestPath)
    }

    /// Writes the adapter script into `dataDir` and the manifest to
    /// `manifestPath`. Idempotent; returns false on any failure.
    @discardableResult
    static func install(dataDir: String, manifestPath: String) -> Bool {
        guard !dataDir.isEmpty, !manifestPath.isEmpty else { return false }
        try? FileManager.default.createDirectory(
            atPath: dataDir, withIntermediateDirectories: true)
        let adapterPath = dataDir + "/" + adapterFileName
        let adapterOK = FileManager.default.createFile(
            atPath: adapterPath, contents: Data(adapterScript.utf8))
        let manifestOK =
            (try? manifestContent(dataDir: dataDir).write(
                toFile: manifestPath, atomically: true, encoding: .utf8)) != nil
        return adapterOK && manifestOK
    }

    /// Removes the manifest and the sibling adapter script. Tolerates
    /// already-missing files.
    static func uninstall(manifestPath: String) {
        try? FileManager.default.removeItem(atPath: manifestPath)
        let dataDir = (manifestPath as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: dataDir + "/" + adapterFileName)
    }
}
