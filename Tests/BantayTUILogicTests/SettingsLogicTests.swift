#if canImport(Testing)
    import Foundation
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
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.contentViewController = controller
            window.makeKeyAndOrderFront(nil)
            #expect(controller.view != nil)
            window.close()
        }

        @Test("AppDelegate does not terminate when last window closes")
        @MainActor
        func appDelegateTerminationBehavior() {
            let delegate = AppDelegate()
            #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp) == false)
        }

        @Test("AppDelegate reopen with visible windows returns true")
        @MainActor
        func appDelegateReopenBehavior() {
            let delegate = AppDelegate()
            #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        }
    }
#endif
