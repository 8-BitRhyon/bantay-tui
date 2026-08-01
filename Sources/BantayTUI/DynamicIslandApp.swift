import AppKit
import SwiftUI

@main
struct DynamicIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    @MainActor static weak var window: NSWindow?
    @MainActor private static let expandedIslandSize = NSSize(width: 456, height: 240)
    @MainActor static var islandWidth: CGFloat = 211
    @MainActor static var islandHeight: CGFloat = 74
    private var statusItem: NSStatusItem?
    private var screenChangeObserver: NSObjectProtocol?

    @MainActor
    static var notchWidth: CGFloat {
        guard let screen = window?.screen ?? NSScreen.main else { return 211 }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        guard screen.safeAreaInsets.top > 0, left > 0, right > 0 else { return 211 }
        let width = screen.frame.width - left - right + 2
        return width > 100 ? width : 211
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makeIslandWindow()
        installMenuBar()
        observeScreenChanges()
    }

    @MainActor
    private func makeIslandWindow() {
        Self.islandWidth = Self.notchWidth + 16
        Self.islandHeight = Self.topInset + 36
        let size = Self.islandSize()
        let window = KeyablePanel(
            contentRect: Self.islandFrame(on: NSScreen.main, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.level = .init(rawValue: Int(Int32.max - 3))
        window.collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        window.canBecomeVisibleWithoutLogin = true
        let hostingController = NSHostingController(
            rootView: NotchStatusView().environmentObject(AgentEventManager.shared))
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.orderFrontRegardless()

        Self.window = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppDelegate.reposition()
                }
            }
        }
    }

    @MainActor
    static var topInset: CGFloat {
        guard let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return 0
        }
        let safe = screen.safeAreaInsets.top
        if safe > 0 {
            return safe
        }
        return screen.frame.maxY - screen.visibleFrame.maxY
    }

    @MainActor
    static func islandFrame(on screen: NSScreen?, size: CGSize) -> NSRect {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(origin: .zero, size: size)
        }
        let positioning = screen.frame
        let frame = NSRect(
            x: positioning.midX - size.width / 2,
            y: positioning.maxY - size.height,
            width: size.width,
            height: size.height)
        return alignedToBackingPixelGrid(frame, scale: screen.backingScaleFactor)
    }

    private static func alignedToBackingPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = max(scale, 1)
        return (value * scale).rounded() / scale
    }

    private static func alignedToBackingPixelGrid(_ frame: NSRect, scale: CGFloat) -> NSRect {
        let minX = alignedToBackingPixel(frame.minX, scale: scale)
        let maxX = alignedToBackingPixel(frame.maxX, scale: scale)
        let minY = alignedToBackingPixel(frame.minY, scale: scale)
        let maxY = alignedToBackingPixel(frame.maxY, scale: scale)
        return NSRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY)
    }

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppDelegate.reposition()
            }
        }
    }

    @MainActor
    static func islandSize() -> NSSize {
        NSSize(width: islandWidth, height: islandHeight)
    }

    @MainActor
    static func resizeIsland(size: NSSize) {
        islandWidth = size.width
        islandHeight = size.height
        reposition()
    }

    @MainActor
    static func showAtNotch() {
        guard let window else { return }
        window.setFrame(islandFrame(on: NSScreen.main, size: islandSize()), display: true)
        window.orderFrontRegardless()
    }

    @MainActor
    static func reposition() {
        guard let window else { return }
        window.setFrame(islandFrame(on: NSScreen.main, size: islandSize()), display: true)
    }

    @MainActor
    static func hide() {
        window?.orderOut(nil)
    }

    @MainActor
    private func installMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "macbook.and.chevron.down",
                accessibilityDescription: "Bantay-TUI")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let titleItem = NSMenuItem(title: "Bantay-TUI", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        let agents = AgentEventManager.shared.agents
        if agents.isEmpty {
            let noneItem = NSMenuItem(title: "No agents active", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            menu.addItem(noneItem)
        } else {
            for agent in agents {
                let item = NSMenuItem(
                    title: "\(agent.source) · \(agent.kind.label)",
                    action: #selector(focusAgent(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = agent.paneId
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        #if DEBUG
            let testItem = NSMenuItem(
                title: "Test Alert",
                action: #selector(testAlert),
                keyEquivalent: "")
            testItem.target = self
            menu.addItem(testItem)
            menu.addItem(.separator())
        #endif

        let quitItem = NSMenuItem(
            title: "Quit Bantay-TUI",
            action: #selector(quitApp),
            keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    #if DEBUG
        @MainActor
        @objc private func testAlert() {
            AgentEventManager.shared.publishForTesting()
        }
    #endif

    @MainActor
    @objc private func focusAgent(_ sender: NSMenuItem) {
        guard let paneId = sender.representedObject as? String else { return }
        HerdrSocketAdapter().paneFocus(paneId: paneId)
    }

    @MainActor
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
