import AppKit
import SwiftUI

extension Notification.Name {
    static let notchVisibilityChanged = Notification.Name("notchVisibilityChanged")
    static let notchHotkeyPressed = Notification.Name("notchHotkeyPressed")
}

@main
struct DynamicIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    @MainActor static weak var window: NSWindow?
    /// The live app-delegate instance, for non-main-actor callbacks.
    @MainActor static weak var shared: AppDelegate?
    /// Set once the island has shown at least once; un-gates `hideAtStartup`.
    @MainActor static var didShowOnce = false
    /// Set at launch when the one-time welcome sheet must appear.
    @MainActor static var pendingWelcome = false
    private var statusItem: NSStatusItem?
    private var screenChangeObserver: NSObjectProtocol?
    private var hotkeyMonitor: Any?
    private var badgeTimer: Timer?
    private var ingestServer: EventIngestServer?

    /// Diagnostic trace written to stderr (landld captures it in bantay.err).
    static func dbg(_ message: String) {
        let line = "[bantay] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        FileHandle.standardError.synchronizeFile()
    }

    @MainActor
    static var notchWidth: CGFloat {
        guard let screen = islandScreen() ?? window?.screen ?? NSScreen.main else {
            return IslandMetrics.notchlessFallbackWidth
        }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        return IslandMetrics.notchWidth(
            screenWidth: screen.frame.width,
            auxLeft: left, auxRight: right,
            safeTop: screen.safeAreaInsets.top)
    }

    @MainActor
    static var topInset: CGFloat {
        guard
            let screen = islandScreen() ?? window?.screen ?? NSScreen.main
                ?? NSScreen.screens.first
        else {
            return 0
        }
        let safe = screen.safeAreaInsets.top
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return IslandMetrics.topInset(safeTop: safe, menuBarHeight: menuBar)
    }

    /// The screen the island should live on: prefers the notch screen under
    /// the mouse; falls back to any notch screen; then the mouse's screen as
    /// a floating pill.
    @MainActor
    static func islandScreen() -> NSScreen? {
        let infos = NSScreen.screens.map { screen in
            IslandMetrics.ScreenInfo(
                frame: screen.frame,
                hasNotch: screen.auxiliaryTopLeftArea != nil
                    || screen.auxiliaryTopRightArea != nil,
                containsMouse: screen.frame.contains(NSEvent.mouseLocation))
        }
        guard
            let chosen = IslandMetrics.islandScreen(
                screens: infos, preferMouseScreen: NotchHUDConfig.shared.followMouseScreen)
        else {
            return NSScreen.main ?? NSScreen.screens.first
        }
        return NSScreen.screens.first { $0.frame == chosen.frame }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Self.shared = self
        makeIslandWindow()
        installMenuBar()
        observeScreenChanges()
        installGlobalHotkey()
        startBadgeTimer()
        updateIngestServer()
        Self.dbg(
            "didFinishLaunching: seen=\(UserDefaults.standard.bool(forKey: "hasSeenOnboarding"))")
        if !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") {
            Self.pendingWelcome = true
        }
        if NotchHUDConfig.shared.hideAtStartup {
            Self.dbg("launch: hideAtStartup set, island stays hidden until an event")
        } else {
            Self.dbg("launch: showing island")
            Self.showAtNotch()
        }
    }

    @MainActor
    private func makeIslandWindow() {
        let size = IslandMetrics.windowSize()
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

        Self.window = window
    }

    @MainActor
    static func islandFrame(on screen: NSScreen?, size: CGSize) -> NSRect {
        let target = screen ?? islandScreen() ?? NSScreen.main ?? NSScreen.screens.first
        guard let target else {
            return NSRect(origin: .zero, size: size)
        }
        let hasNotch =
            target.auxiliaryTopLeftArea != nil
            || target.auxiliaryTopRightArea != nil
        if !hasNotch, NotchHUDConfig.shared.floatingPillOnNoNotch {
            let menuBar = target.frame.maxY - target.visibleFrame.maxY
            return IslandMetrics.floatingPillFrame(
                screenFrame: target.frame, size: size, menuBarHeight: menuBar)
        }
        return IslandMetrics.windowFrame(
            screenFrame: target.frame, size: size, scale: target.backingScaleFactor)
    }

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppDelegate.reposition() }
        }
    }

    @MainActor
    static func showAtNotch() {
        guard let window else { return }
        didShowOnce = true
        reposition()
        window.orderFrontRegardless()
    }

    @MainActor
    static func reposition() {
        guard let window else { return }
        window.setFrame(
            islandFrame(on: window.screen ?? NSScreen.main, size: IslandMetrics.windowSize()),
            display: true)
    }

    @MainActor
    static func hide() {
        window?.orderOut(nil)
    }

    /// A small pill-ish template icon. SF Symbols like `macbook.and.chevron.down`
    /// are missing on some macOS versions, and a nil image on the status button
    /// renders as an invisible menu trigger — so draw the icon ourselves so the
    /// menu bar button is always visible.
    @MainActor
    private static func makeTrayIconImage() -> NSImage {
        if let symbol = NSImage(
            systemSymbolName: "chevron.down", accessibilityDescription: "Bantay-TUI")
        {
            return symbol
        }
        let icon = NSImage(size: NSSize(width: 18, height: 18))
        icon.lockFocus()
        let pill = NSBezierPath(
            roundedRect: NSRect(x: 4, y: 7, width: 10, height: 7), xRadius: 3, yRadius: 3)
        NSColor.labelColor.setFill()
        pill.fill()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 9, y: 4))
        arrow.line(to: NSPoint(x: 6, y: 6))
        arrow.line(to: NSPoint(x: 12, y: 6))
        arrow.close()
        arrow.fill()
        icon.unlockFocus()
        icon.isTemplate = true
        return icon
    }

    @MainActor
    private func installMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.makeTrayIconImage()
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Global ⌥Space toggle: show/hide the island from anywhere. Uses a
    /// key-down monitor so no Accessibility permission is required.
    @MainActor
    private func installGlobalHotkey() {
        guard NotchHUDConfig.shared.globalHotkeyEnabled else { return }
        let handler: @Sendable (NSEvent) -> Void = { event in
            guard event.modifierFlags.contains(.option),
                !event.modifierFlags.contains(.shift),
                event.keyCode == 49  // Space
            else {
                return
            }
            Task { @MainActor in
                AppDelegate.handleHotkeyToggle()
            }
        }
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    @MainActor
    static func handleHotkeyToggle() {
        if window?.isVisible == true {
            hide()
        } else {
            showAtNotch()
            NotificationCenter.default.post(name: .notchHotkeyPressed, object: nil)
        }
    }

    /// Menu-bar badge: a small amber dot + pending count when approvals wait.
    @MainActor
    private func startBadgeTimer() {
        updateBadge()
        let handler: @Sendable (Timer) -> Void = { _ in
            Task { @MainActor in
                AppDelegate.shared?.updateBadge()
            }
        }
        badgeTimer = Timer.scheduledTimer(
            withTimeInterval: 3.0, repeats: true, block: handler)
    }

    @MainActor
    private func updateBadge() {
        guard let button = statusItem?.button else { return }
        let config = NotchHUDConfig.shared
        let needsInput = IslandMetrics.agentCounts(
            kinds: AgentEventManager.shared.agents.map(\.kind)
        ).needsInput
        if config.menuBarBadge && needsInput > 0 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.systemOrange,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                .paragraphStyle: paragraph,
            ]
            button.attributedTitle = NSAttributedString(
                string: " •\(needsInput)", attributes: attrs)
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    /// Start/stop the remote event-ingest listener per config. Remote agents
    /// tunnel into it (`ssh -R <port>:localhost:<port>`) and POST event
    /// lines that enter the same pipeline as local events.
    @MainActor
    func updateIngestServer() {
        ingestServer?.stop()
        ingestServer = nil
        let config = NotchHUDConfig.shared
        guard config.ingestEnabled else { return }
        let manager = AgentEventManager.shared
        let server = EventIngestServer(port: IngestHTTP.clampedPort(config.ingestPort)) { line in
            Task { @MainActor in
                manager.ingestEventLine(line)
            }
        }
        server.start()
        ingestServer = server
        Self.dbg(
            "ingest: listening on 127.0.0.1:\(config.ingestPort) "
                + "(ssh -R \(config.ingestPort):localhost:\(config.ingestPort))")
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

        let pollingItem = NSMenuItem(
            title: "Poll agents",
            action: #selector(togglePolling(_:)),
            keyEquivalent: "")
        pollingItem.target = self
        pollingItem.state = NotchHUDConfig.shared.captureEnabled ? .on : .off
        menu.addItem(pollingItem)

        let alertsItem = NSMenuItem(
            title: "Alert sounds",
            action: #selector(toggleAlerts(_:)),
            keyEquivalent: "")
        alertsItem.target = self
        alertsItem.state = NotchHUDConfig.shared.enableAgentAlerts ? .on : .off
        menu.addItem(alertsItem)

        menu.addItem(.separator())

        let config = NotchHUDConfig.shared
        let disableItem = NSMenuItem(
            title: config.islandEnabled ? "Disable Island" : "Enable Island",
            action: #selector(toggleIslandEnabled),
            keyEquivalent: "")
        disableItem.target = self
        menu.addItem(disableItem)

        let snoozeMenu = NSMenu()
        let snoozeItem = NSMenuItem(
            title: config.isSnoozed ? "Snooze active" : "Snooze…",
            action: nil,
            keyEquivalent: "")
        snoozeItem.submenu = snoozeMenu
        snoozeItem.state = config.isSnoozed ? .on : .off
        let presets: [(String, TimeInterval)] = [
            ("15 minutes", 900),
            ("1 hour", 3600),
            ("4 hours", 14400),
        ]
        for (label, seconds) in presets {
            let item = NSMenuItem(
                title: label, action: #selector(snoozePreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            snoozeMenu.addItem(item)
        }
        let untilRestart = NSMenuItem(
            title: "Until next restart",
            action: #selector(snoozeUntilRestartToggle),
            keyEquivalent: "")
        untilRestart.target = self
        untilRestart.state = config.snoozeUntilRestart ? .on : .off
        snoozeMenu.addItem(untilRestart)
        snoozeMenu.addItem(.separator())
        let cancelSnooze = NSMenuItem(
            title: "Cancel snooze", action: #selector(cancelSnooze), keyEquivalent: "")
        cancelSnooze.target = self
        cancelSnooze.isEnabled = config.isSnoozed
        snoozeMenu.addItem(cancelSnooze)
        menu.addItem(snoozeItem)

        let restartItem = NSMenuItem(
            title: "Restart pipeline",
            action: #selector(restartPipeline),
            keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

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

        let uninstallItem = NSMenuItem(
            title: "Remove Bantay-TUI…",
            action: #selector(uninstallPrompt),
            keyEquivalent: "")
        uninstallItem.target = self
        uninstallItem.isEnabled = Self.uninstallScriptPath() != nil
        menu.addItem(uninstallItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

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
    @objc private func togglePolling(_ sender: NSMenuItem) {
        let config = NotchHUDConfig.shared
        config.captureEnabled.toggle()
        if config.captureEnabled {
            AgentEventManager.shared.startCapture()
        } else {
            AgentEventManager.shared.stopCapture()
        }
        sender.state = config.captureEnabled ? .on : .off
    }

    @MainActor
    @objc private func toggleAlerts(_ sender: NSMenuItem) {
        let config = NotchHUDConfig.shared
        config.enableAgentAlerts.toggle()
        sender.state = config.enableAgentAlerts ? .on : .off
    }

    @MainActor
    @objc private func toggleIslandEnabled() {
        let config = NotchHUDConfig.shared
        config.islandEnabled.toggle()
        NotificationCenter.default.post(name: .notchVisibilityChanged, object: nil)
    }

    @MainActor
    @objc private func snoozePreset(_ sender: NSMenuItem) {
        let config = NotchHUDConfig.shared
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        config.snoozeUntilRestart = false
        config.snoozedUntil = Date().addingTimeInterval(seconds)
        NotificationCenter.default.post(name: .notchVisibilityChanged, object: nil)
    }

    @MainActor
    @objc private func snoozeUntilRestartToggle() {
        let config = NotchHUDConfig.shared
        config.snoozeUntilRestart.toggle()
        if config.snoozeUntilRestart {
            config.snoozedUntil = nil
        }
        NotificationCenter.default.post(name: .notchVisibilityChanged, object: nil)
    }

    @MainActor
    @objc private func cancelSnooze() {
        let config = NotchHUDConfig.shared
        config.snoozeUntilRestart = false
        config.snoozedUntil = nil
        NotificationCenter.default.post(name: .notchVisibilityChanged, object: nil)
    }

    @MainActor
    @objc private func restartPipeline() {
        AgentEventManager.shared.stopCapture()
        AgentEventManager.shared.startCapture()
    }

    @MainActor
    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let settingsWindow =
            (NSApp.windows.first { $0.title == "Bantay-TUI Settings" })
            ?? makeSettingsWindow()
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Bantay-TUI Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    /// Locates the installed `setup.sh` used by the in-app uninstall path.
    @MainActor
    private static func uninstallScriptPath() -> String? {
        let candidates: [String?] = [
            NSHomeDirectory() + "/Library/Application Support/Bantay-TUI/setup.sh",
            Bundle.main.resourceURL?.appendingPathComponent("scripts/setup.sh").path,
            FileManager.default.currentDirectoryPath + "/scripts/setup.sh",
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    @MainActor
    @objc private func uninstallPrompt() {
        guard let script = Self.uninstallScriptPath() else {
            let alert = NSAlert()
            alert.messageText = "Setup script not found"
            alert.informativeText = "Install Bantay-TUI with scripts/setup.sh first."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Uninstall Bantay-TUI?"
        alert.informativeText =
            "Removes the launch agent, app binary, and event history. "
            + "Your herdr sessions are untouched."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script, "--uninstall"]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    NSApp.terminate(nil)
                }
            } catch {
                // Nothing was removed; leave the app running.
            }
        }
    }
}
