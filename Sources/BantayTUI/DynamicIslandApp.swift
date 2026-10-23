import AppKit
import Combine
import Network
import SwiftUI

@main
struct DynamicIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.handleEarlyCommandLineArguments()
    }

    private static func sendSocketCommand(method: String, params: [String: Any]) {
        let socketPath = ControlGateway.socketPath()
        guard FileManager.default.fileExists(atPath: socketPath) else {
            fputs("[bantay] Daemon socket not found at \(socketPath)\n", stderr)
            exit(1)
        }
        let sema = DispatchSemaphore(value: 0)
        let id = "cli:\(method)"
        let paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        let paramsString = String(data: paramsData, encoding: .utf8) ?? "{}"
        let line = "{\"id\":\"\(id)\",\"method\":\"\(method)\",\"params\":\(paramsString)}\n"
        let endpoint = NWEndpoint.unix(path: socketPath)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "bantay.cli.socket", qos: .userInitiated)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(
                    content: Data(line.utf8),
                    completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
                    data, _, _, _ in
                    if let data = data, let str = String(data: data, encoding: .utf8) {
                        print(str.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    sema.signal()
                }
            } else if case .failed = state {
                sema.signal()
            }
        }
        connection.start(queue: queue)
        _ = sema.wait(timeout: .now() + 2.0)
        connection.cancel()
        exit(0)
    }

    private static func handleEarlyCommandLineArguments() {
        if CommandLine.arguments.contains("--mcp") || CommandLine.arguments.contains("mcp") {
            BantayMCPServer.runStdioLoop()
            exit(0)
        }
        if CommandLine.arguments.contains("--ping") || CommandLine.arguments.contains("ping") {
            sendSocketCommand(method: "bantay.ping", params: [:])
        }
        if CommandLine.arguments.contains("--settings")
            || CommandLine.arguments.contains("settings")
        {
            sendSocketCommand(method: "settings.open", params: [:])
        }
        if CommandLine.arguments.contains("--permissions")
            || CommandLine.arguments.contains("permissions")
        {
            let granted = StripWindowRegistry.hasAccessibilityPermission()
            if granted {
                print("Accessibility permission: GRANTED")
            } else {
                print("Accessibility permission: NOT GRANTED")
                print("Opening macOS System Settings Privacy & Security > Accessibility...")
                StripWindowRegistry.promptAccessibilityPermission()
                StripWindowRegistry.openAccessibilitySettings()
            }
            exit(0)
        }
        if let stripIdx = CommandLine.arguments.firstIndex(where: {
            $0 == "strip" || $0 == "--strip"
        }) {
            let sub =
                CommandLine.arguments.indices.contains(stripIdx + 1)
                ? CommandLine.arguments[stripIdx + 1] : "toggle"
            let argumentStart = stripIdx + 2
            func option(_ flag: String, default defaultValue: String) -> String {
                let arguments = CommandLine.arguments
                if let flagIndex = arguments.indices.first(where: {
                    $0 >= argumentStart && arguments[$0] == flag
                }), arguments.indices.contains(flagIndex + 1) {
                    return arguments[flagIndex + 1]
                }
                if arguments.indices.contains(argumentStart) {
                    let candidate = arguments[argumentStart]
                    if !candidate.hasPrefix("--") {
                        return candidate
                    }
                }
                return defaultValue
            }
            switch sub {
            case "toggle":
                sendSocketCommand(method: "strip.toggle", params: [:])
            case "focus":
                let dir = option("--dir", default: "right")
                sendSocketCommand(method: "strip.focus", params: ["direction": dir])
            case "center":
                sendSocketCommand(method: "strip.center", params: [:])
            case "width":
                let mode = option("--mode", default: "cycle")
                sendSocketCommand(method: "strip.width", params: ["mode": mode])
            case "approval":
                sendSocketCommand(method: "strip.approval", params: [:])
            case "status":
                sendSocketCommand(method: "strip.status", params: [:])
            case "overview":
                sendSocketCommand(method: "strip.overview", params: [:])
            case "reorder":
                let arguments = CommandLine.arguments
                let from: Int
                let to: Int
                if let fromIndex = arguments.firstIndex(of: "--from"),
                    let toIndex = arguments.firstIndex(of: "--to"),
                    arguments.indices.contains(fromIndex + 1),
                    arguments.indices.contains(toIndex + 1)
                {
                    from = Int(arguments[fromIndex + 1]) ?? 0
                    to = Int(arguments[toIndex + 1]) ?? 1
                } else {
                    let fromRaw =
                        arguments.indices.contains(stripIdx + 2)
                        ? arguments[stripIdx + 2] : "0"
                    let toRaw =
                        arguments.indices.contains(stripIdx + 3)
                        ? arguments[stripIdx + 3] : "1"
                    from = Int(fromRaw) ?? 0
                    to = Int(toRaw) ?? 1
                }
                sendSocketCommand(method: "strip.reorder", params: ["from": from, "to": to])
            case "autochain":
                let slug = option("--slug", default: "")
                sendSocketCommand(
                    method: "strip.autochain", params: slug.isEmpty ? [:] : ["slug": slug])
            case "pin":
                let col =
                    CommandLine.arguments.indices.contains(stripIdx + 2)
                    ? Int(CommandLine.arguments[stripIdx + 2]) : nil
                sendSocketCommand(
                    method: "strip.pin",
                    params: col != nil ? ["columnIndex": col!] : [:])
            case "stack":
                let dir =
                    CommandLine.arguments.indices.contains(stripIdx + 2)
                    ? CommandLine.arguments[stripIdx + 2] : "right"
                sendSocketCommand(method: "strip.stack", params: ["direction": dir])
            case "unstack":
                let dir =
                    CommandLine.arguments.indices.contains(stripIdx + 2)
                    ? CommandLine.arguments[stripIdx + 2] : "right"
                let toRight = (dir != "left")
                sendSocketCommand(method: "strip.unstack", params: ["toRight": toRight])
            case "tabbed":
                let col =
                    CommandLine.arguments.indices.contains(stripIdx + 2)
                    ? Int(CommandLine.arguments[stripIdx + 2]) : nil
                sendSocketCommand(
                    method: "strip.tabbed",
                    params: col != nil ? ["columnIndex": col!] : [:])
            default:
                sendSocketCommand(method: "strip.toggle", params: [:])
            }
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// The island's borderless panel. File drops are handled by SwiftUI `.onDrop`
/// on the island content (NotchDrop pattern) — no AppKit drag machinery here,
/// which fought the hosting view and refused every drop.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    override init() {
        super.init()
        Self.dbg("AppDelegate.init called")
    }

    @MainActor static var window: NSWindow?
    /// The live app-delegate instance, for non-main-actor callbacks.
    @MainActor static var shared: AppDelegate?
    /// Set once the island has shown at least once; un-gates `hideAtStartup`.
    @MainActor static var didShowOnce = false
    /// True while the user has forced the island visible via the tray menu.
    @MainActor static var isForcedVisible = false
    /// The island hid itself for a full-screen app and should return when the
    /// user leaves that Space.
    @MainActor static var fullScreenHidIsland = false
    /// Set at launch when the one-time welcome sheet must appear.
    @MainActor static var pendingWelcome = false
    /// Mirror of the island's F2 compose field state (set by NotchStatusView)
    /// so global approve/deny hotkeys never fire while a prompt is being
    /// typed — same guard the in-island Y/N shortcuts use.
    @MainActor static var composingPaneId: String?
    private var statusItem: NSStatusItem?
    private var screenChangeObserver: NSObjectProtocol?
    private var spaceChangeObserver: NSObjectProtocol?
    private var fullScreenCancellable: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?
    @MainActor private static var settleTask: Task<Void, Never>?
    private var hotkeyMonitors: [Any] = []
    private var dragMonitor: NotchDragMonitor?
    private var didLogHotkeyPermissionWarning = false
    private var badgeTimer: Timer?
    private var ingestServer: EventIngestServer?
    private var controlGateway: ControlGatewayServer?
    /// The "Remove Bantay-TUI…" menu item; disabled while the uninstall
    /// script runs so the action can't double-fire.
    @MainActor private var uninstallMenuItem: NSMenuItem?

    /// Diagnostic trace written to stderr (launchd captures it in bantay.err).
    static func dbg(_ message: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let line = "[bantay] [\(pid)] \(message)\n"
        fputs(line, stderr)
        fflush(stderr)
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

    /// Width of the menu-bar icon cluster left of the notch (0 when the OS
    /// does not report auxiliary areas).
    @MainActor
    static var auxLeftWidth: CGFloat {
        islandScreen()?.auxiliaryTopLeftArea?.width ?? 0
    }

    /// Width of the menu-bar icon cluster right of the notch (0 when the OS
    /// does not report auxiliary areas).
    @MainActor
    static var auxRightWidth: CGFloat {
        islandScreen()?.auxiliaryTopRightArea?.width ?? 0
    }

    /// The screen the island should live on: prefers the notch screen under
    /// the mouse; falls back to any notch screen; then the mouse's screen as
    /// a floating pill.
    @MainActor
    static func islandScreen() -> NSScreen? {
        let infos = NSScreen.screens.map { screen in
            IslandMetrics.ScreenInfo(
                frame: screen.frame,
                hasNotch: IslandMetrics.hasNotch(
                    safeTop: screen.safeAreaInsets.top,
                    auxLeft: screen.auxiliaryTopLeftArea?.width ?? 0,
                    auxRight: screen.auxiliaryTopRightArea?.width ?? 0),
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
        FullScreenMonitor.shared.start()
        bindFullScreenMonitor()
        // Data dir + events file always exist (setup.sh parity) so the
        // events pipeline and LaunchAgent logs have a home.
        LaunchAgent.ensureDataDirectory()
        makeIslandWindow()
        installMenuBar()
        observeScreenChanges()
        updateGlobalHotkeyMonitor()
        let monitor = NotchDragMonitor()
        dragMonitor = monitor
        monitor.start()
        startBadgeTimer()
        updateIngestServer()
        updateControlGateway()
        NotificationCenter.default.addObserver(
            forName: .openSettingsRequested,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                Self.dbg("Notification openSettingsRequested received, calling showSettings")
                AppDelegate.showSettings()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .stripToggleRequested,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                StripWindowManager.shared.toggle()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .stripFocusRequested,
            object: nil,
            queue: .main
        ) { note in
            let dir = (note.userInfo?["direction"] as? String) ?? "right"
            MainActor.assumeIsolated {
                StripWindowManager.shared.focusColumn(direction: dir)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .stripCenterRequested,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                StripWindowManager.shared.centerActiveColumn()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .stripWidthRequested,
            object: nil,
            queue: .main
        ) { note in
            let mode = (note.userInfo?["mode"] as? String) ?? "cycle"
            MainActor.assumeIsolated {
                StripWindowManager.shared.cycleWidth(mode: mode)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .stripApprovalRequested,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                StripWindowManager.shared.jumpToApprovalAgent()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .stripOverviewRequested,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                StripWindowManager.shared.toggleOverviewMode()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .stripReorderRequested,
            object: nil,
            queue: .main
        ) { note in
            let from = (note.userInfo?["from"] as? Int) ?? 0
            let to = (note.userInfo?["to"] as? Int) ?? 1
            MainActor.assumeIsolated {
                StripWindowManager.shared.reorderColumn(fromIndex: from, toIndex: to)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .stripAutochainRequested,
            object: nil,
            queue: .main
        ) { note in
            let slug = note.userInfo?["slug"] as? String
            _ = MainActor.assumeIsolated {
                StripWindowManager.shared.autoChainCurrentProject(slug: slug)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .stripPinRequested,
            object: nil,
            queue: .main
        ) { note in
            let col = note.userInfo?["columnIndex"] as? Int
            MainActor.assumeIsolated {
                StripWindowManager.shared.togglePin(columnIndex: col)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .stripStackRequested,
            object: nil,
            queue: .main
        ) { note in
            let dir = (note.userInfo?["direction"] as? String) ?? "right"
            MainActor.assumeIsolated {
                StripWindowManager.shared.stack(direction: dir)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .stripUnstackRequested,
            object: nil,
            queue: .main
        ) { note in
            let toRight = (note.userInfo?["toRight"] as? Bool) ?? true
            MainActor.assumeIsolated {
                StripWindowManager.shared.unstack(toRight: toRight)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .stripTabbedRequested,
            object: nil,
            queue: .main
        ) { note in
            let col = note.userInfo?["columnIndex"] as? Int
            MainActor.assumeIsolated {
                StripWindowManager.shared.toggleTabbed(columnIndex: col)
            }
        }
        StripStatusProvider.current = { StripWindowManager.shared.statusSnapshot() }
        StripWindowManager.shared.start()
        Self.dbg(
            "didFinishLaunching: seen=\(UserDefaults.standard.bool(forKey: "hasSeenOnboarding"))")
        if !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") {
            Self.pendingWelcome = true
        }
        let config = NotchHUDConfig.shared
        if AgentEventManager.shared.agents.isEmpty {
            config.panelPinned = false
        }
        if CommandLine.arguments.contains("--settings")
            || CommandLine.arguments.contains("settings")
        {
            openSettings()
        }
        let shouldShowAtLaunch =
            Self.isForcedVisible
            || IslandMetrics.FullScreenPolicy.shouldShow(
                inFullScreen: FullScreenMonitor.shared.isFullScreen,
                showInFullScreen: config.showInFullScreen)
        if config.hideAtStartup && !config.showIslandWhenIdle {
            Self.dbg("launch: hideAtStartup set, island stays hidden until an event")
        } else if shouldShowAtLaunch {
            Self.dbg(
                "launch: showing island (hideAtStartup=\(config.hideAtStartup) idleShow=\(config.showIslandWhenIdle))"
            )
            Self.showAtNotch()
        } else {
            Self.dbg("launch: full screen active, island stays hidden")
        }
    }

    @MainActor
    private func bindFullScreenMonitor() {
        fullScreenCancellable = FullScreenMonitor.shared.$isFullScreen
            .receive(on: DispatchQueue.main)
            .sink { isFullScreen in
                Task { @MainActor in
                    AppDelegate.handleFullScreenStateChange(isFullScreen)
                }
            }
    }

    @MainActor
    private func makeIslandWindow() {
        let size = IslandMetrics.windowSize()
        guard size.width > 0, size.height > 0 else {
            Self.dbg("startup guard: invalid window size \(size), exiting")
            NSApp.terminate(nil)
            return
        }
        guard let frame = Self.islandFrame(on: NSScreen.main, size: size) as NSRect?,
            frame.width > 0, frame.height > 0
        else {
            Self.dbg("startup guard: invalid island frame, exiting")
            NSApp.terminate(nil)
            return
        }
        let window = KeyablePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        guard window.screen != nil else {
            Self.dbg("startup guard: window server refused panel screen, exiting")
            NSApp.terminate(nil)
            return
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        // Set window level to statusBar + 8 for drag-and-drop support.
        window.level = .statusBar + 8
        window.collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        window.canBecomeVisibleWithoutLogin = true
        window.isReleasedWhenClosed = false
        // FileDropContentView provides AppKit drag-and-drop registration for the island.
        let dropView = FileDropContentView(
            rootView: NotchStatusView().environmentObject(AgentEventManager.shared))
        window.contentView = dropView

        Self.window = window
    }

    @MainActor
    static func islandFrame(on screen: NSScreen?, size: CGSize) -> NSRect {
        let target = screen ?? islandScreen() ?? NSScreen.main ?? NSScreen.screens.first
        guard let target else {
            return NSRect(origin: .zero, size: size)
        }
        let hasNotch = IslandMetrics.hasNotch(
            safeTop: target.safeAreaInsets.top,
            auxLeft: target.auxiliaryTopLeftArea?.width ?? 0,
            auxRight: target.auxiliaryTopRightArea?.width ?? 0)
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
            MainActor.assumeIsolated { AppDelegate.handleDisplayChange() }
        }
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppDelegate.handleSpaceChange() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppDelegate.handleDisplayChange() }
        }
    }

    /// Debounced display hot-plug / wake handler: let the WindowServer
    /// settle, then re-anchor the island and purge ghost windows.
    @MainActor
    static func handleDisplayChange() {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(IslandMetrics.FullScreenPolicy.transitionSettleDelay))
            guard !Task.isCancelled else { return }
            FullScreenMonitor.shared.refreshNow()
            applyFullScreenPolicy(isFullScreen: FullScreenMonitor.shared.isFullScreen)
            reanchorIfGhosted()
            reposition()
            if window?.isVisible == true { showAtNotch() }
        }
    }

    /// If the island is visible but its frame is off every current screen
    /// (display disconnected, clamshell closed), move it back on-screen.
    @MainActor
    static func reanchorIfGhosted() {
        guard let window else { return }
        let screens = NSScreen.screens.map(\.frame)
        if IslandMetrics.DisplayAnchor.needsReanchor(
            isVisible: window.isVisible, windowFrame: window.frame, screens: screens)
        {
            reposition()
            Self.dbg("display: ghost window re-anchored")
        }
    }

    /// Re-evaluate island visibility after a full-screen change and re-anchor
    /// once the WindowServer settles the new frame.
    @MainActor
    static func handleFullScreenStateChange(_ isFullScreen: Bool) {
        applyFullScreenPolicy(isFullScreen: isFullScreen)
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(IslandMetrics.FullScreenPolicy.transitionSettleDelay))
            guard !Task.isCancelled else { return }
            applyFullScreenPolicy(isFullScreen: isFullScreen)
        }
    }

    /// Applies the user's "Keep island in full screen" preference without
    /// resurrecting an island the user or launch settings left hidden.
    @MainActor
    static func applyFullScreenPolicy(isFullScreen: Bool) {
        let shouldShow =
            isForcedVisible
            || IslandMetrics.FullScreenPolicy.shouldShow(
                inFullScreen: isFullScreen,
                showInFullScreen: NotchHUDConfig.shared.showInFullScreen)

        guard shouldShow else {
            if window?.isVisible == true {
                fullScreenHidIsland = true
            }
            hide()
            return
        }

        if isFullScreen {
            // Keep an already-visible island anchored. Do not reveal one that
            // hideAtStartup or the tray left hidden.
            if window?.isVisible == true || isForcedVisible {
                showAtNotch()
            }
            return
        }

        if fullScreenHidIsland {
            fullScreenHidIsland = false
            showAtNotch()
        } else if window?.isVisible == true || isForcedVisible {
            showAtNotch()
        }
    }

    /// Re-anchor after a space switch (spaces can move/scale the island).
    @MainActor
    static func handleSpaceChange() {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(IslandMetrics.FullScreenPolicy.transitionSettleDelay))
            guard !Task.isCancelled else { return }
            FullScreenMonitor.shared.refreshNow()
            applyFullScreenPolicy(isFullScreen: FullScreenMonitor.shared.isFullScreen)
            reposition()
            if window?.isVisible == true { showAtNotch() }
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

    /// Installs global Option-key shortcut monitors for island toggle, approvals, and snooze.
    @MainActor
    func updateGlobalHotkeyMonitor() {
        for monitor in hotkeyMonitors {
            NSEvent.removeMonitor(monitor)
        }
        hotkeyMonitors.removeAll()
        let config = NotchHUDConfig.shared
        guard config.globalHotkeyEnabled else { return }
        let enabledActions: [(UInt16, IslandMetrics.HotkeyAction)] = [
            (49, .toggleIsland),
            (16, .approveTop),
            (45, .denyTop),
            (1, .snooze15),
            (43, .openSettings),
        ].filter { keyCode, action in
            switch action {
            case .toggleIsland: return true
            case .approveTop: return config.globalHotkeyApproveEnabled
            case .denyTop: return config.globalHotkeyDenyEnabled
            case .snooze15: return config.globalHotkeySnoozeEnabled
            case .openSettings: return true
            }
        }
        for (_, action) in enabledActions {
            let handler: @Sendable (NSEvent) -> Void = { event in
                guard
                    IslandMetrics.hotkeyAction(
                        keyCode: event.keyCode, modifiers: event.modifierFlags) == action
                else {
                    return
                }
                Task { @MainActor in
                    AppDelegate.handleHotkeyAction(action)
                }
            }
            if let monitor = NSEvent.addGlobalMonitorForEvents(
                matching: .keyDown, handler: handler)
            {
                hotkeyMonitors.append(monitor)
            } else if !didLogHotkeyPermissionWarning {
                didLogHotkeyPermissionWarning = true
                Self.dbg(
                    "hotkeys: Input Monitoring untrusted — global monitor unavailable, menu-bar controls still work"
                )
            }
        }
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

    /// Dispatches a global hotkey action to the appropriate handler.
    @MainActor
    static func handleHotkeyAction(_ action: IslandMetrics.HotkeyAction) {
        switch action {
        case .toggleIsland:
            handleHotkeyToggle()
        case .approveTop:
            performApprovalHotkey(approve: true)
        case .denyTop:
            performApprovalHotkey(approve: false)
        case .snooze15:
            let config = NotchHUDConfig.shared
            config.snoozeUntilRestart = false
            config.snoozedUntil = Date().addingTimeInterval(900)
            NotificationCenter.default.post(name: .notchVisibilityChanged, object: nil)
        case .openSettings:
            showSettings()
        }
    }

    @MainActor
    private static func performApprovalHotkey(approve: Bool) {
        guard composingPaneId == nil else { return }
        if window?.isKeyWindow == true,
            let responder = window?.firstResponder,
            responder is NSText || responder is NSTextField
        {
            return
        }
        let manager = AgentEventManager.shared
        let muted = NotchHUDConfig.shared.mutedSources
        let roster =
            muted.isEmpty
            ? manager.agents
            : manager.agents.filter {
                !muted.contains($0.source)
            }
        let merged = manager.mergeApprovals(into: roster)
        let top = merged.first { $0.kind == .accessRequest || $0.kind == .waiting }
        guard let paneId = top?.paneId, !manager.isResolving(paneId: paneId) else { return }
        #if os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
        if approve {
            manager.approve(paneId: paneId)
        } else {
            manager.deny(paneId: paneId)
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

    /// Configures and starts TCP and Unix socket ingest listeners per configuration.
    @MainActor
    func updateIngestServer() {
        ingestServer?.stop()
        ingestServer = nil
        let config = NotchHUDConfig.shared
        guard config.ingestEnabled || config.ingestSocketEnabled else { return }
        let manager = AgentEventManager.shared
        let server = EventIngestServer(
            port: IngestHTTP.clampedPort(config.ingestPort),
            token: config.ingestToken,
            onLine: { line in
                Task { @MainActor in
                    manager.ingestEventLine(line)
                }
            },
            onAction: { action in
                Task { @MainActor in
                    switch action {
                    case .approve(let paneId):
                        manager.approve(paneId: paneId)
                    case .deny(let paneId):
                        manager.deny(paneId: paneId)
                    case .choice(let paneId, let index):
                        manager.approveChoice(paneId: paneId, choice: index)
                    }
                }
            }
        )
        if config.ingestEnabled {
            server.start()
            Self.dbg(
                "ingest: listening on 127.0.0.1:\(config.ingestPort) "
                    + "(ssh -R \(config.ingestPort):localhost:\(config.ingestPort))")
        }
        if config.ingestSocketEnabled {
            server.startUnixSocket()
            Self.dbg(
                "ingest: UDS \(EventIngestServer.ingestSocketPath()) "
                    + "(HTTP POST or `token <secret>` + one event line)")
        }
        ingestServer = server
    }

    /// Start/stop the local control gateway (W1 wire contract) per config.
    /// A Unix-domain socket owned by the current user is not a network
    /// exposure, so the facet defaults ON; the stale-socket probe on start
    /// unlinks leftovers from a crash.
    @MainActor
    func updateControlGateway() {
        controlGateway?.stop()
        controlGateway = nil
        let config = NotchHUDConfig.shared
        guard config.gatewayEnabled else { return }
        let path = ControlGateway.socketPath(
            env: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
        let server = ControlGatewayServer(socketPath: path, adapter: HerdrSocketAdapter())
        server.start()
        controlGateway = server
        Self.dbg("gateway: listening on \(path)")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let titleItem = NSMenuItem(title: "Bantay-TUI", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        let agents = AgentEventManager.shared.agents
        let topApproval = agents.first { $0.kind == .accessRequest || $0.kind == .waiting }
        if let topApproval,
            let paneId = IslandMetrics.actionablePaneId(
                paneId: topApproval.paneId, source: topApproval.source)
        {
            let cleanPrompt =
                topApproval.title.flatMap {
                    let c = IslandMetrics.cleanHUDText($0, maxCharacters: 40)
                    return c.isEmpty ? nil : ": \(c)"
                } ?? ""
            let approveTitle = "✓ Approve \(topApproval.source)\(cleanPrompt)"
            let approveItem = NSMenuItem(
                title: approveTitle,
                action: #selector(approveAgent(_:)),
                keyEquivalent: "y"
            )
            approveItem.keyEquivalentModifierMask = [.option]
            approveItem.target = self
            approveItem.representedObject = paneId
            menu.addItem(approveItem)

            let denyItem = NSMenuItem(
                title: "✕ Deny \(topApproval.source)",
                action: #selector(denyAgent(_:)),
                keyEquivalent: "n"
            )
            denyItem.keyEquivalentModifierMask = [.option]
            denyItem.target = self
            denyItem.representedObject = paneId
            menu.addItem(denyItem)
            menu.addItem(.separator())
        }

        if agents.isEmpty {
            let noneItem = NSMenuItem(title: "No agents active", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            menu.addItem(noneItem)
        } else {
            let rosterHeader = NSMenuItem(
                title: "Agents (\(agents.count))", action: nil, keyEquivalent: "")
            rosterHeader.isEnabled = false
            menu.addItem(rosterHeader)

            for agent in agents {
                let isBlocked =
                    agent.kind == .accessRequest || agent.kind == .waiting
                let glyph: String = {
                    switch agent.kind {
                    case .accessRequest, .waiting: return "🟡"
                    case .failed: return "🔴"
                    case .completed: return "🔵"
                    case .progress, .started: return "🟢"
                    default: return agent.isWorking ? "🟢" : "⚪️"
                    }
                }()
                let slug = agent.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                let cleanTitle = agent.title.flatMap {
                    let c = IslandMetrics.cleanHUDText($0, maxCharacters: 40)
                    return c.isEmpty ? nil : c
                }
                let desc = cleanTitle ?? agent.kind.label
                let label =
                    "\(glyph) \(agent.source)\(slug.map { " (\($0))" } ?? "") — \(desc)"
                let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                let submenu = NSMenu()

                if isBlocked,
                    let paneId = IslandMetrics.actionablePaneId(
                        paneId: agent.paneId, source: agent.source)
                {
                    let header = NSMenuItem(
                        title: "\(agent.source) needs approval", action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    submenu.addItem(header)
                    submenu.addItem(.separator())
                    let controls = agent.approval
                    if controls.isYesNo {
                        submenu.addItem(
                            menuItem(
                                title: "Approve", action: #selector(approveAgent(_:)),
                                paneId: paneId))
                        submenu.addItem(
                            menuItem(
                                title: "Deny", action: #selector(denyAgent(_:)),
                                paneId: paneId))
                    } else {
                        let labels = controls.optionLabels
                        for (index, optLabel) in labels.enumerated() {
                            let text =
                                controls.choices.indices.contains(index)
                                ? controls.choices[index] : "Option \(optLabel)"
                            submenu.addItem(
                                menuItem(
                                    title: "\(optLabel). \(text)",
                                    action: #selector(approveChoiceAgent(_:)),
                                    paneId: paneId,
                                    extra: String(index)))
                        }
                        if controls.optionLabels.isEmpty {
                            submenu.addItem(
                                menuItem(
                                    title: "Approve", action: #selector(approveAgent(_:)),
                                    paneId: paneId))
                        }
                    }
                    submenu.addItem(.separator())
                }

                if let paneId = agent.paneId {
                    submenu.addItem(
                        menuItem(
                            title: "Focus Window", action: #selector(focusAgent(_:)),
                            paneId: paneId))
                    submenu.addItem(
                        menuItem(
                            title: "View Session in Browser",
                            action: #selector(viewSessionInBrowser(_:)),
                            paneId: paneId))
                }
                item.submenu = submenu
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
        let showItem = NSMenuItem(
            title: Self.isForcedVisible ? "Hide Island" : "Show Island",
            action: #selector(toggleForcedVisible),
            keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
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
        uninstallMenuItem = uninstallItem
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
        if paneId.hasPrefix("standalone:") {
            let stripped = paneId.replacingOccurrences(of: "standalone:", with: "")
            let components = stripped.split(separator: ":")
            let agentName = String(components.first ?? "")
            let agent = AgentEventManager.shared.agents.first { $0.paneId == paneId }
            TerminalFocusser.focusStandalone(source: agentName, cwd: agent?.cwd)
        } else if OpenCodeActionWriter.isOpenCodePane(paneId) {
            let agent = AgentEventManager.shared.agents.first { $0.paneId == paneId }
            TerminalFocusser.focusStandalone(source: "opencode", cwd: agent?.cwd)
        } else {
            AgentEventManager.shared.performAction(paneId: paneId) { $0.focusPane(paneId: paneId) }
        }
    }

    @MainActor
    @objc private func viewSessionInBrowser(_ sender: NSMenuItem) {
        guard let paneId = sender.representedObject as? String else { return }
        let agent = AgentEventManager.shared.agents.first { $0.paneId == paneId }
        let source = agent?.source ?? "agent"
        let slug = agent?.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? source
        RichSessionViewer.openInBrowser(
            agentName: source,
            projectSlug: slug,
            cwd: agent?.cwd,
            isWorking: agent?.isWorking ?? false,
            sessionPath: agent?.sessionPath
        )
    }

    /// Helper for a menu item whose target is this delegate and whose
    /// representedObject is the pane id (optionally with an index suffix for
    /// numbered choices).
    @MainActor
    private func menuItem(
        title: String, action: Selector, paneId: String, extra: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = extra.map { "\(paneId)|\($0)" } ?? paneId
        return item
    }

    @MainActor
    @objc private func approveAgent(_ sender: NSMenuItem) {
        guard let paneId = sender.representedObject as? String else { return }
        AgentEventManager.shared.approve(paneId: paneId)
    }

    @MainActor
    @objc private func denyAgent(_ sender: NSMenuItem) {
        guard let paneId = sender.representedObject as? String else { return }
        AgentEventManager.shared.deny(paneId: paneId)
    }

    @MainActor
    @objc private func approveChoiceAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let index = Int(parts[1]) else { return }
        let paneId = parts[0]
        let number = IslandMetrics.ApprovalControls.optionNumber(forIndex: index)
        AgentEventManager.shared.approveChoice(paneId: paneId, choice: number)
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
    @objc private func toggleForcedVisible() {
        Self.isForcedVisible.toggle()
        if Self.isForcedVisible {
            Self.didShowOnce = true
            Self.fullScreenHidIsland = false
            Self.showAtNotch()
        } else {
            Self.fullScreenHidIsland = false
            Self.hide()
        }
        NotificationCenter.default.post(name: .notchVisibilityChanged, object: nil)
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

    @MainActor private var settingsWindowInstance: NSWindow?

    @MainActor
    static func showSettings() {
        shared?.openSettings()
    }

    @MainActor
    @objc func openSettings() {
        Self.dbg("openSettings: 1 start")
        let window = settingsWindowInstance ?? makeSettingsWindow()
        Self.dbg("openSettings: 2 window obtained")
        settingsWindowInstance = window
        NotificationCenter.default.post(name: .settingsWillOpen, object: nil)
        Self.dbg("openSettings: 3 settingsWillOpen posted")
        if let targetScreen = Self.islandScreen() ?? NSScreen.main {
            let screenRect = targetScreen.visibleFrame
            let x = screenRect.midX - window.frame.width / 2
            let y = screenRect.midY - window.frame.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }
        Self.dbg("openSettings: 4 frame set")
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        Self.dbg("openSettings: 5 makeKeyAndOrderFront")
        window.makeKeyAndOrderFront(nil)
        Self.dbg("openSettings: 6 orderFrontRegardless")
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        Self.dbg("openSettings: 7 done")
    }

    @MainActor
    private func makeSettingsWindow() -> NSWindow {
        Self.dbg("makeSettingsWindow: 1 creating window")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Bantay-TUI Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        Self.dbg("makeSettingsWindow: 2 creating NSHostingController")
        window.contentViewController = NSHostingController(rootView: SettingsView())
        Self.dbg("makeSettingsWindow: 3 NSHostingController created")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 480)
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Stay above the island panel (`.statusBar + 8`) so opening Settings
        // never leaves the notch covering its controls.
        window.level = .statusBar + 9
        Self.dbg("makeSettingsWindow: 4 done")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        Self.dbg("AppDelegate: windowWillClose called: \(notification.name)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.dbg("AppDelegate: applicationWillTerminate called!")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            openSettings()
        }
        return true
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
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Run the script through the non-blocking runner so the menu action
        // returns immediately; the menu item stays disabled until the script
        // finishes (or fails). A long timeout keeps the script from being
        // killed mid-write by the 3s default.
        uninstallMenuItem?.isEnabled = false
        Task { @MainActor in
            let result = await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [script, "--uninstall"],
                timeout: 120)
            self.uninstallMenuItem?.isEnabled = Self.uninstallScriptPath() != nil
            if result.status == 0 {
                NSApp.terminate(nil)
            }
        }
    }
}
