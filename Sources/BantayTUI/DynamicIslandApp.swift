import AppKit
import SwiftUI

@main
struct DynamicIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var eventManager = AgentEventManager()

    var body: some Scene {
        WindowGroup {
            NotchStatusView()
                .environmentObject(eventManager)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let window = NSApplication.shared.windows.first else { return }
        Self.window = window

        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.borderless)
        window.isMovableByWindowBackground = false
        window.ignoresMouseEvents = false

        window.orderOut(nil)
    }

    @MainActor
    static func showAtNotch() {
        guard let window else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let notchHeight = screen.safeAreaInsets.top
        let visibleFrame = screen.visibleFrame
        let screenFrame = screen.frame

        let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
        let topY =
            notchHeight > 0
            ? screenFrame.maxY - notchHeight - 6
            : screenFrame.maxY - menuBarHeight - 6

        let x = screenFrame.midX - window.frame.width / 2

        window.setFrameOrigin(NSPoint(x: x, y: topY - window.frame.height))
        window.orderFrontRegardless()
    }

    @MainActor
    static func hide() {
        window?.orderOut(nil)
    }
}
