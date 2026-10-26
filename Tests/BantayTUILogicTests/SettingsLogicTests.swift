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

        @Test("Settings window can be created, ordered front, and refreshed")
        @MainActor
        func settingsWindowLifecycle() {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false)
            window.title = "Bantay-TUI Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            let view = SettingsView()
            window.contentViewController = NSHostingController(rootView: view)
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .settingsWillOpen, object: nil)
            #expect(window.isVisible)
            window.close()
        }

        @Test("settings.open route is recognized by ControlGateway")
        func settingsGatewayRoute() {
            #expect(ControlGateway.GatewayRoute.isKnown("settings.open"))
            #expect(ControlGateway.route(method: "settings.open") == .openSettings)
        }

        @Test("Option+Comma hotkey maps to openSettings action")
        func settingsHotkeyAction() {
            let action = IslandMetrics.hotkeyAction(keyCode: 43, modifiers: .option)
            #expect(action == .openSettings)
            let withExtra = IslandMetrics.hotkeyAction(
                keyCode: 43, modifiers: [.option, .shift])
            #expect(withExtra == nil)
        }
    }
#endif
