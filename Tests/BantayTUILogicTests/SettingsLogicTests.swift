#if canImport(Testing)
    import AppKit
    import Foundation
    import SwiftUI
    import Testing

    @testable import BantayTUI

    @Suite("LaunchAgent logic", .serialized)
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

        @Test("SettingsView can be instantiated and hosted")
        @MainActor
        func settingsViewHosting() {
            let view = SettingsView()
            let controller = NSHostingController(rootView: view)
            _ = controller.view
            #expect(controller.isViewLoaded)
        }
    }
#endif
