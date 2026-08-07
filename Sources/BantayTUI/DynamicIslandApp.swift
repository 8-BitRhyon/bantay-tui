import AppKit
import SwiftUI

extension Notification.Name {
    static let notchVisibilityChanged = Notification.Name("notchVisibilityChanged")
    static let notchHotkeyPressed = Notification.Name("notchHotkeyPressed")
    static let settingsWillOpen = Notification.Name("settingsWillOpen")
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

/// The island's borderless panel. Also serves as an `NSDraggingDestination`
/// so dropping files onto the notch — expanded or not, on any tab — opens
/// the shelf and lands the files there (NotchDrop-style drop-on-notch).
final class KeyablePanel: NSPanel, NSDraggingDestination {
    override var canBecomeKey: Bool { true }

    override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { setupFileDrag() }
    }

    override init(
        contentRect: NSRect, styleMask style: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        MainActor.assumeIsolated { setupFileDrag() }
    }

    private func setupFileDrag() {
        registerForDraggedTypes([.fileURL])
    }

    /// Accept any drag carrying file URLs; announce so the view can expand
    /// and switch to the shelf tab while the user is hovering over the notch.
    /// Uses a TYPE check (`availableType`) not `readObjects`: reading the
    /// drag pasteboard during draggingEntered returns empty on modern macOS,
    /// which makes the window refuse the drop (the circle-with-cross cursor).
    /// The actual URLs are read in performDragOperation, where reading works.
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        guard
            pb.availableType(from: [.fileURL]) != nil
                || pb.availableType(from: [NSPasteboard.PasteboardType(rawValue: "public.file-url")]
                )
                    != nil
        else {
            return []
        }
        NotificationCenter.default.post(name: .notchFileDragEntered, object: nil)
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        // No-op: the panel stays on the shelf tab; only a successful drop
        // matters. The expanded state collapses on hover-exit as usual.
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self])
                as? [URL], !urls.isEmpty
        else {
            return false
        }
        NotificationCenter.default.post(
            name: .notchFilesDropped, object: nil, userInfo: ["urls": urls])
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    @MainActor static weak var window: NSWindow?
    /// The live app-delegate instance, for non-main-actor callbacks.
    @MainActor static weak var shared: AppDelegate?
    /// Set once the island has shown at least once; un-gates `hideAtStartup`.
    @MainActor static var didShowOnce = false
    /// True while the user has forced the island visible via the tray menu.
    @MainActor static var isForcedVisible = false
    /// Set at launch when the one-time welcome sheet must appear.
    @MainActor static var pendingWelcome = false
    /// Mirror of the island's F2 compose field state (set by NotchStatusView)
    /// so global approve/deny hotkeys never fire while a prompt is being
    /// typed — same guard the in-island Y/N shortcuts use.
    @MainActor static var composingPaneId: String?
    private var statusItem: NSStatusItem?
    private var screenChangeObserver: NSObjectProtocol?
    private var fullScreenObserver: NSObjectProtocol?
    private var fullScreenExitObserver: NSObjectProtocol?
    private var spaceChangeObserver: NSObjectProtocol?
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
        Self.dbg(
            "didFinishLaunching: seen=\(UserDefaults.standard.bool(forKey: "hasSeenOnboarding"))")
        if !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") {
            Self.pendingWelcome = true
        }
        let config = NotchHUDConfig.shared
        if config.hideAtStartup && !config.showIslandWhenIdle {
            Self.dbg("launch: hideAtStartup set, island stays hidden until an event")
        } else {
            Self.dbg(
                "launch: showing island (hideAtStartup=\(config.hideAtStartup) idleShow=\(config.showIslandWhenIdle))"
            )
            Self.showAtNotch()
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
        window.level = .init(rawValue: Int(Int32.max - 3))
        window.collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        window.canBecomeVisibleWithoutLogin = true
        // Use a DragAcceptingHostingView (not NSHostingController) so the
        // content view itself is the NSDraggingDestination — drag events land
        // on the view under the cursor, and a window-level registration never
        // fires because the hosting view swallows the drag.
        let hosting = DragAcceptingHostingView(
            rootView: NotchStatusView().environmentObject(AgentEventManager.shared))
        window.contentView = hosting

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
        fullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppDelegate.handleFullScreenTransition() }
        }
        fullScreenExitObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppDelegate.handleFullScreenTransition() }
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

    /// Re-evaluate island visibility after a full-screen transition and
    /// re-anchor once the WindowServer settles the new frame.
    @MainActor
    static func handleFullScreenTransition() {
        settleTask?.cancel()
        if IslandMetrics.FullScreenPolicy.shouldShow(
            inFullScreen: true, showInFullScreen: NotchHUDConfig.shared.showInFullScreen)
        {
            showAtNotch()
        } else {
            hide()
        }
        settleTask = Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(IslandMetrics.FullScreenPolicy.transitionSettleDelay))
            guard !Task.isCancelled else { return }
            if IslandMetrics.FullScreenPolicy.shouldShow(
                inFullScreen: true, showInFullScreen: NotchHUDConfig.shared.showInFullScreen)
            {
                showAtNotch()
            } else {
                hide()
            }
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

    /// Global ⌥-key shortcuts: toggle (⌥Space), approve top (⌥Y), deny top
    /// (⌥N), snooze 15m (⌥S). One key-down monitor per enabled action, so a
    /// disabled facet stops installing immediately in both directions. Uses
    /// key-down monitors so no Accessibility permission is required; when
    /// Input Monitoring is untrusted the monitor comes back nil — log once
    /// and leave the menu-bar fallbacks working.
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
        ].filter { keyCode, action in
            switch action {
            case .toggleIsland: return true
            case .approveTop: return config.globalHotkeyApproveEnabled
            case .denyTop: return config.globalHotkeyDenyEnabled
            case .snooze15: return config.globalHotkeySnoozeEnabled
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

    /// Dispatch a global hotkey action. Approve/deny route through the event
    /// manager for the top pending approval, guarded exactly like the
    /// in-island Y/N shortcuts (no compose field open, not resolving) so an
    /// approval is never dropped or double-fired. Snooze mirrors the 15m menu
    /// preset.
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
        }
    }

    @MainActor
    private static func performApprovalHotkey(approve: Bool) {
        guard composingPaneId == nil else { return }
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
        manager.performAction(paneId: paneId) { adapter in
            if approve {
                adapter.approve(paneId: paneId)
            } else {
                adapter.deny(paneId: paneId)
            }
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

    /// Start/stop the remote event-ingest listeners per config. Remote agents
    /// tunnel into the TCP listener (`ssh -R <port>:localhost:<port>`) and
    /// POST event lines that enter the same pipeline as local events; the
    /// user-owned Unix socket (default on) serves local scripts via HTTP
    /// POST or the bare `token <secret>` + event-line form.
    @MainActor
    func updateIngestServer() {
        ingestServer?.stop()
        ingestServer = nil
        let config = NotchHUDConfig.shared
        guard config.ingestEnabled || config.ingestSocketEnabled else { return }
        let manager = AgentEventManager.shared
        let server = EventIngestServer(
            port: IngestHTTP.clampedPort(config.ingestPort),
            token: config.ingestToken
        ) { line in
            Task { @MainActor in
                manager.ingestEventLine(line)
            }
        }
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
        if agents.isEmpty {
            let noneItem = NSMenuItem(title: "No agents active", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            menu.addItem(noneItem)
        } else {
            for agent in agents {
                let isBlocked =
                    agent.kind == .accessRequest || agent.kind == .waiting
                if isBlocked, agent.paneId != nil {
                    // Submenu per blocked agent: Approve / Deny (+ choices).
                    let submenu = NSMenu()
                    let header = NSMenuItem(
                        title: "\(agent.source) needs approval", action: nil,
                        keyEquivalent: "")
                    header.isEnabled = false
                    submenu.addItem(header)
                    submenu.addItem(.separator())
                    let controls = agent.approval
                    if controls.isYesNo {
                        submenu.addItem(
                            menuItem(
                                title: "Approve", action: #selector(approveAgent(_:)),
                                paneId: agent.paneId!))
                        submenu.addItem(
                            menuItem(
                                title: "Deny", action: #selector(denyAgent(_:)),
                                paneId: agent.paneId!))
                    } else if controls.isMulti {
                        let labels = controls.optionLabels
                        for (index, label) in labels.enumerated() {
                            let text =
                                controls.choices.indices.contains(index)
                                ? controls.choices[index] : "Option \(label)"
                            submenu.addItem(
                                menuItem(
                                    title: "\(label). \(text)",
                                    action: #selector(approveChoiceAgent(_:)),
                                    paneId: agent.paneId!,
                                    extra: String(index)))
                        }
                        submenu.addItem(
                            menuItem(
                                title: "Approve (all selected)",
                                action: #selector(approveAgent(_:)),
                                paneId: agent.paneId!))
                    } else {
                        let labels = controls.optionLabels
                        for (index, label) in labels.enumerated() {
                            let text =
                                controls.choices.indices.contains(index)
                                ? controls.choices[index] : "Option \(label)"
                            submenu.addItem(
                                menuItem(
                                    title: "\(label). \(text)",
                                    action: #selector(approveChoiceAgent(_:)),
                                    paneId: agent.paneId!,
                                    extra: String(index)))
                        }
                        if controls.optionLabels.isEmpty {
                            submenu.addItem(
                                menuItem(
                                    title: "Approve", action: #selector(approveAgent(_:)),
                                    paneId: agent.paneId!))
                        }
                    }
                    submenu.addItem(.separator())
                    submenu.addItem(
                        menuItem(
                            title: "Focus terminal", action: #selector(focusAgent(_:)),
                            paneId: agent.paneId!))
                    let item = NSMenuItem(
                        title: "⚠︎ \(agent.source) — \(agent.title ?? "needs approval")",
                        action: nil, keyEquivalent: "")
                    item.submenu = submenu
                    menu.addItem(item)
                } else {
                    let item = NSMenuItem(
                        title: "\(agent.source) · \(agent.kind.label)",
                        action: #selector(focusAgent(_:)),
                        keyEquivalent: "")
                    item.target = self
                    item.representedObject = agent.paneId
                    menu.addItem(item)
                }
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
        HerdrSocketAdapter().paneFocus(paneId: paneId)
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
        AgentEventManager.shared.performAction(paneId: paneId) { $0.approve(paneId: paneId) }
    }

    @MainActor
    @objc private func denyAgent(_ sender: NSMenuItem) {
        guard let paneId = sender.representedObject as? String else { return }
        AgentEventManager.shared.performAction(paneId: paneId) { $0.deny(paneId: paneId) }
    }

    @MainActor
    @objc private func approveChoiceAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let index = Int(parts[1]) else { return }
        let paneId = parts[0]
        let number = IslandMetrics.ApprovalControls.optionNumber(forIndex: index)
        AgentEventManager.shared.performAction(paneId: paneId) {
            $0.approveChoice(paneId: paneId, choice: number)
        }
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
            Self.showAtNotch()
        } else {
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

    @MainActor
    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let settingsWindow =
            (NSApp.windows.first { $0.title == "Bantay-TUI Settings" })
            ?? makeSettingsWindow()
        // The window persists across close/reopen, so the view re-reads its
        // state from config (menu-bar toggles may have changed it since).
        NotificationCenter.default.post(name: .settingsWillOpen, object: nil)
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Bantay-TUI Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 900)
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
