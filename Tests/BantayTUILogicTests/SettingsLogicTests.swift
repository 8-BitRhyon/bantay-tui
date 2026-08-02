import Foundation
import Testing

@testable import BantayTUI

@Suite(.serialized, "LaunchAgent logic")
struct SettingsLogicTests {
    @Test("plist presence drives isInstalled")
    func plistPresence() {
        let tmp = NSTemporaryDirectory() + "/bantay-settings-\(UUID().uuidString).plist"
        let old = LaunchAgent.plistPath
        LaunchAgent.plistPath = tmp
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            LaunchAgent.plistPath = old
        }
        #expect(!LaunchAgent.isInstalled)
        FileManager.default.createFile(atPath: tmp, contents: Data(), attributes: nil)
        #expect(LaunchAgent.isInstalled)
        try? FileManager.default.removeItem(atPath: tmp)
        #expect(!LaunchAgent.isInstalled)
    }

    @Test("launchctl exit status drives isLoaded")
    func loadStatus() {
        let old = LaunchAgent.processRunner
        defer { LaunchAgent.processRunner = old }
        LaunchAgent.processRunner = { _ in 0 }
        #expect(LaunchAgent.isLoaded())
        LaunchAgent.processRunner = { _ in 113 }
        #expect(!LaunchAgent.isLoaded())
    }
}
