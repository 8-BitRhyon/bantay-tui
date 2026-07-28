import SwiftUI
import AppKit

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
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let window = NSApplication.shared.windows.first else { return }

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

        positionWindowAtNotch(window)
    }

    @MainActor
    private func positionWindowAtNotch(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let notchHeight = screen.safeAreaInsets.top
        let visibleFrame = screen.visibleFrame
        let screenFrame = screen.frame

        let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
        let topY = notchHeight > 0
            ? screenFrame.maxY - notchHeight - 6
            : screenFrame.maxY - menuBarHeight - 6

        let windowWidth = window.frame.width
        let x = screenFrame.midX - windowWidth / 2

        window.setFrameOrigin(NSPoint(x: x, y: topY - window.frame.height))
    }
}
