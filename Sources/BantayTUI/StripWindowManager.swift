import AppKit
import Combine
import Foundation

/// Main coordinator for the infinite scrolling agent strip on macOS.
@MainActor
public final class StripWindowManager: ObservableObject {
    public static let shared = StripWindowManager()

    @Published public var config: StripConfiguration {
        didSet {
            config.save()
            updateViewportBounds()
            updateLayout(animate: false)
        }
    }

    @Published public private(set) var columns: [StripColumn] = []
    @Published public private(set) var activeColumnIndex: Int = 0
    @Published public private(set) var viewport: StripViewport
    @Published public private(set) var layoutResult: StripLayoutResult = StripLayoutResult()
    @Published public var isOverviewMode: Bool = false
    /// True while the frontmost app is full screen. The strip suspends its
    /// overlays and window tiling so it cannot cover or resize the full-screen
    /// app the user is working in.
    @Published public private(set) var isFullScreen: Bool = false

    private let registry = StripWindowRegistry.shared
    private let animator: StripViewportAnimator
    private let overlay = StripOverlayRenderer.shared
    private let interceptor = StripGestureInterceptor.shared

    private var appActivateObserver: Any?
    private var screenChangeObserver: Any?
    private var syncTimer: Timer?
    private var eventCancellable: AnyCancellable?
    private var fullScreenCancellable: AnyCancellable?
    private var viewportScreen: NSScreen?

    private init() {
        let loadedConfig = StripConfiguration.load()
        self.config = loadedConfig
        self.viewport = StripViewport(
            gap: loadedConfig.gap,
            inset: loadedConfig.inset
        )
        self.animator = StripViewportAnimator()

        setupAnimator()
        updateViewportBounds()
    }

    private func setupAnimator() {
        animator.onUpdate = { [weak self] currentScroll in
            guard let self else { return }
            self.viewport.scrollOffset = currentScroll
            self.applyComputedFrames()
        }

        animator.onFinished = { [weak self] in
            guard let self else { return }
            self.applyComputedFrames()
        }
    }

    /// Starts the scrolling window manager service.
    public func start() {
        guard config.isEnabled else { return }

        if !StripWindowRegistry.hasAccessibilityPermission() {
            StripWindowRegistry.promptAccessibilityPermission()
        }

        updateViewportBounds()
        interceptor.start()
        FullScreenMonitor.shared.start()
        bindFullScreenMonitor()

        // Mirror the current value immediately; the strip may start while the
        // user is already inside a full-screen app.
        isFullScreen = FullScreenMonitor.shared.isFullScreen
        if isFullScreen {
            overlay.hideAll()
        }

        // 1. Observe active application switches
        appActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppActivated()
            }
        }

        // 2. Observe screen / display changes
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateViewportBounds()
                self?.updateLayout(animate: false)
            }
        }

        // 3. Periodic synchronization for window lifecycle (open/close/move)
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncWindows()
            }
        }

        // 4. Auto-center on agent approval event
        eventCancellable = AgentEventManager.shared.$currentEvent
            .compactMap { $0 }
            .filter { $0.kind == .accessRequest || $0.kind == .waiting }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.config.isEnabled, self.config.autoCenterOnApproval else {
                    return
                }
                self.syncWindows()
                self.jumpToApproval()
            }

        syncWindows()
        updateLayout(animate: false)
    }

    /// Stops the scrolling window manager service.
    public func stop() {
        interceptor.stop()
        animator.stop()
        overlay.hideAll()

        if let appActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivateObserver)
            self.appActivateObserver = nil
        }
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        syncTimer?.invalidate()
        syncTimer = nil
        eventCancellable?.cancel()
        eventCancellable = nil
        fullScreenCancellable?.cancel()
        fullScreenCancellable = nil
    }

    private func bindFullScreenMonitor() {
        fullScreenCancellable?.cancel()
        fullScreenCancellable = FullScreenMonitor.shared.$isFullScreen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self, self.isFullScreen != value else { return }
                self.isFullScreen = value
                if value {
                    self.overlay.hideAll()
                    self.animator.stop()
                } else {
                    self.syncWindows()
                    self.updateLayout(animate: true)
                }
            }
    }

    /// Toggles the strip window manager on or off.
    public func toggle(enabled: Bool? = nil) {
        if let enabled {
            config.isEnabled = enabled
        } else {
            config.isEnabled.toggle()
        }

        if config.isEnabled {
            if !StripWindowRegistry.hasAccessibilityPermission() {
                StripWindowRegistry.promptAccessibilityPermission()
            }
            start()
        } else {
            stop()
        }
    }

    /// Re-anchors viewport dimensions to current active display visible frame.
    public func updateViewportBounds() {
        let mouseLoc = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1710, height: 1000)
        viewportScreen = screen

        viewport.screenOriginX = vf.origin.x
        viewport.screenOriginY = vf.origin.y
        viewport.screenWidth = vf.width
        viewport.screenHeight = vf.height
        viewport.gap = config.gap
        viewport.inset = config.inset
    }

    /// Discovers system windows and reconciles them into strip columns.
    public func syncWindows() {
        guard config.isEnabled, !isFullScreen else { return }
        let discovered = registry.scanWindows(ignoredBundleIDs: config.ignoredBundleIDs)
        guard !discovered.isEmpty else { return }

        // Track the exact focused window, not just the frontmost PID. This
        // keeps the active column and focused tab correct when one app owns
        // several windows on different parts of the strip.
        let focusedWindowID = registry.frontmostWindowID()

        let discoveredMap = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        var updatedColumns: [StripColumn] = []

        // 1. Retain existing columns with fresh metadata
        for var col in columns {
            var updatedWins: [StripWindowInfo] = []
            for win in col.windows {
                if let fresh = discoveredMap[win.id] {
                    updatedWins.append(fresh)
                }
            }
            if !updatedWins.isEmpty {
                col.windows = updatedWins
                col.focusedRow = min(col.focusedRow, updatedWins.count - 1)
                updatedColumns.append(col)
            }
        }

        // 2. Insert new windows adjacent to active column
        let existingIDs = Set(updatedColumns.flatMap { $0.windows.map(\.id) })
        let newWindows = discovered.filter { !existingIDs.contains($0.id) }

        if !newWindows.isEmpty {
            var insertionIndex = min(activeColumnIndex + 1, updatedColumns.count)
            let targetIdx = insertionIndex
            for newWin in newWindows {
                let newCol = StripColumn(
                    windows: [newWin],
                    widthFraction: config.defaultWidthPreset,
                    isTabbed: false,
                    focusedRow: 0
                )
                updatedColumns.insert(newCol, at: insertionIndex)
                insertionIndex += 1
            }
            self.columns = updatedColumns
            activeColumnIndex = targetIdx
            let oldActive = activeColumnIndex
            reconcileFocusedWindow(focusedWindowID)
            updateLayout(animate: oldActive != activeColumnIndex)
            return
        }

        self.columns = updatedColumns
        if activeColumnIndex >= columns.count {
            activeColumnIndex = max(0, columns.count - 1)
        }

        let oldActive = activeColumnIndex
        reconcileFocusedWindow(focusedWindowID)
        updateLayout(animate: oldActive != activeColumnIndex)
    }

    /// Keeps the active column and focused tab on the window the user is
    /// actually using. A PID match is not enough: one app can own several
    /// windows in different columns or tabs.
    private func reconcileFocusedWindow(_ windowID: String?) {
        guard let windowID,
            let location = StripLayoutEngine.findWindow(id: windowID, columns: columns)
        else { return }
        activeColumnIndex = location.column
        columns[location.column].focusedRow = location.row
    }

    private func handleAppActivated() {
        guard config.isEnabled, !isFullScreen else { return }
        FullScreenMonitor.shared.scheduleRefresh(after: 0.1)

        let focusedWindowID = registry.frontmostWindowID()
        if let focusedWindowID,
            let location = StripLayoutEngine.findWindow(id: focusedWindowID, columns: columns)
        {
            activeColumnIndex = location.column
            columns[location.column].focusedRow = location.row
            centerCurrentColumn()
            return
        }

        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        for (colIdx, col) in columns.enumerated() {
            if let rowIdx = col.windows.firstIndex(where: { $0.pid == frontPID }) {
                activeColumnIndex = colIdx
                columns[colIdx].focusedRow = rowIdx
                centerCurrentColumn()
                return
            }
        }
    }

    /// Recalculates strip layout and pushes target coordinates to the viewport.
    public func updateLayout(animate: Bool) {
        if isOverviewMode {
            layoutResult = StripLayoutEngine.computeOverviewLayout(
                columns: columns, viewport: viewport)
            animator.snapTo(target: 0.0)
            applyComputedFrames()
            return
        }

        layoutResult = StripLayoutEngine.computeLayout(columns: columns, viewport: viewport)

        let targetScroll = StripLayoutEngine.revealTarget(
            columnIndex: activeColumnIndex,
            columns: columns,
            viewport: viewport
        )

        if animate {
            animator.animateTo(target: targetScroll, omega: config.springOmega)
        } else {
            animator.snapTo(target: targetScroll)
        }
    }

    private func applyComputedFrames() {
        guard config.isEnabled else {
            overlay.hideAll()
            return
        }

        if isOverviewMode {
            layoutResult = StripLayoutEngine.computeOverviewLayout(
                columns: columns, viewport: viewport)
        } else {
            layoutResult = StripLayoutEngine.computeLayout(columns: columns, viewport: viewport)
        }

        // Full screen suspends the strip. Computing the layout keeps status
        // snapshots fresh, but applying frames here would resize the
        // full-screen window and can drop it out of full screen.
        guard !isFullScreen else {
            overlay.hideAll()
            return
        }

        // Apply frames to native windows. A full-screen window is skipped even
        // if the global monitor tick is one frame behind, so the strip can
        // never resize an app out of full screen.
        for (winID, frame) in layoutResult.windowFrames
        where !registry.isWindowFullScreen(windowID: winID) {
            registry.applyFrame(windowID: winID, frame: frame)
        }

        // Update floating status halos
        let focusedWinID =
            columns.indices.contains(activeColumnIndex)
            ? columns[activeColumnIndex].activeWindow?.id
            : nil

        let screenRect =
            viewportScreen?.frame
            ?? NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1710, height: 1000)

        let allWindows = columns.flatMap(\.windows)
        overlay.updateHalos(
            windows: allWindows,
            frames: layoutResult.windowFrames,
            focusedWindowID: focusedWinID,
            enabled: config.statusHalosEnabled,
            dimInactive: config.dimInactive,
            showChevrons: config.showNavigationChevrons,
            canFocusLeft: activeColumnIndex > 0,
            canFocusRight: activeColumnIndex < columns.count - 1,
            screenBounds: screenRect
        )
    }

    /// Toggles bird's-eye zoom overview mode where all columns fit on a single screen without scrolling.
    public func toggleOverviewMode() {
        isOverviewMode.toggle()
        updateLayout(animate: true)
    }

    /// Reorders a column from one index to another (via drag-and-drop or gesture).
    public func reorderColumn(fromIndex: Int, toIndex: Int) {
        guard StripLayoutEngine.reorder(fromIndex: fromIndex, toIndex: toIndex, columns: &columns)
        else { return }
        if activeColumnIndex == fromIndex {
            activeColumnIndex = toIndex
        }
        updateLayout(animate: true)
    }

    /// Automatically chains every open window into an agent triage workflow.
    /// Scans the live window roster so the chain includes windows that were
    /// never synced into a column. Enables the strip when needed.
    @discardableResult
    public func autoChainCurrentProject(slug: String? = nil) -> Bool {
        let wasEnabled = config.isEnabled
        if !wasEnabled {
            config.isEnabled = true
        }

        let scanned = registry.scanWindows(ignoredBundleIDs: config.ignoredBundleIDs)
        let candidates = scanned.isEmpty ? columns.flatMap(\.windows) : scanned
        let chained = StripLayoutEngine.autoChainWorkflow(windows: candidates, projectSlug: slug)
        guard !chained.isEmpty else { return false }

        columns = chained
        activeColumnIndex = 0

        if wasEnabled {
            updateLayout(animate: true)
        } else {
            start()
        }
        return true
    }

    /// Best-effort project slug from the active window's agent working
    /// directory. Returns nil when the active window is not an agent.
    public func currentProjectSlug() -> String? {
        guard columns.indices.contains(activeColumnIndex),
            let cwd = columns[activeColumnIndex].activeWindow?.agentCwd,
            !cwd.isEmpty
        else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Sendable snapshot of the live strip state for the control gateway.
    public func statusSnapshot() -> StripStatusSnapshot {
        StripStatusSnapshot(
            enabled: config.isEnabled,
            defaultWidthPreset: config.defaultWidthPreset,
            gap: config.gap,
            inset: config.inset,
            overview: isOverviewMode,
            isFullScreen: isFullScreen,
            activeColumnIndex: activeColumnIndex,
            accessibility: StripWindowRegistry.hasAccessibilityPermission(),
            columns: columns.enumerated().map { index, column in
                StripStatusSnapshot.Column(
                    index: index,
                    widthFraction: column.widthFraction,
                    isTabbed: column.isTabbed,
                    isPinned: column.isPinned,
                    activeWindowID: column.activeWindow?.id ?? "",
                    activeWindowTitle: column.activeWindow?.title ?? "",
                    windows: column.windows.map { window in
                        StripStatusSnapshot.Window(
                            id: window.id,
                            pid: window.pid,
                            appBundleID: window.appBundleID,
                            title: window.title,
                            agent: window.agentName ?? "",
                            agentCwd: window.agentCwd ?? "",
                            status: window.agentStatus.rawValue
                        )
                    }
                )
            }
        )
    }

    // MARK: - Navigation & Window Actions

    public func focusLeft() {
        guard !columns.isEmpty else { return }
        activeColumnIndex = max(0, activeColumnIndex - 1)
        focusActiveWindow()
        scrollToColumn(activeColumnIndex, animated: true)
    }

    public func focusRight() {
        guard !columns.isEmpty else { return }
        activeColumnIndex = min(columns.count - 1, activeColumnIndex + 1)
        focusActiveWindow()
        scrollToColumn(activeColumnIndex, animated: true)
    }

    /// Cycles to the next window inside the active column. Works for tabbed
    /// stacks and for columns that show several windows vertically.
    public func focusNextWindow() {
        cycleFocusedRow(forward: true)
    }

    /// Cycles to the previous window inside the active column.
    public func focusPreviousWindow() {
        cycleFocusedRow(forward: false)
    }

    private func cycleFocusedRow(forward: Bool) {
        guard columns.indices.contains(activeColumnIndex) else { return }
        let count = columns[activeColumnIndex].windows.count
        guard count > 1 else { return }
        let current = columns[activeColumnIndex].focusedRow
        columns[activeColumnIndex].focusedRow =
            forward
            ? StripLayoutEngine.nextRow(current: current, count: count)
            : StripLayoutEngine.previousRow(current: current, count: count)
        focusActiveWindow()
        updateLayout(animate: false)
    }

    /// Jumps to the first column on the strip.
    public func focusFirstColumn() {
        jumpToColumn(index: 0)
    }

    /// Jumps to the last column on the strip.
    public func focusLastColumn() {
        guard !columns.isEmpty else { return }
        jumpToColumn(index: columns.count - 1)
    }

    public func moveLeft() {
        guard activeColumnIndex > 0 else { return }
        let target = activeColumnIndex - 1
        _ = StripLayoutEngine.reorder(
            fromIndex: activeColumnIndex,
            toIndex: target,
            columns: &columns
        )
        activeColumnIndex = target
        scrollToColumn(activeColumnIndex, animated: true)
    }

    public func moveRight() {
        guard activeColumnIndex < columns.count - 1 else { return }
        let target = activeColumnIndex + 1
        _ = StripLayoutEngine.reorder(
            fromIndex: activeColumnIndex,
            toIndex: target,
            columns: &columns
        )
        activeColumnIndex = target
        scrollToColumn(activeColumnIndex, animated: true)
    }

    public func cycleWidth() {
        guard columns.indices.contains(activeColumnIndex) else { return }
        let current = columns[activeColumnIndex].widthFraction
        let next = StripLayoutEngine.cycleWidth(currentFraction: current)
        columns[activeColumnIndex].widthFraction = next
        updateLayout(animate: true)
    }

    public func toggleFullWidth() {
        guard columns.indices.contains(activeColumnIndex) else { return }
        let current = columns[activeColumnIndex].widthFraction
        let saved = columns[activeColumnIndex].savedFraction
        let (newFraction, newSaved) = StripLayoutEngine.toggleFullWidth(
            currentFraction: current,
            savedFraction: saved
        )
        columns[activeColumnIndex].widthFraction = newFraction
        columns[activeColumnIndex].savedFraction = newSaved
        updateLayout(animate: true)
    }

    public func centerCurrentColumn() {
        guard columns.indices.contains(activeColumnIndex) else { return }
        let centerTarget = StripLayoutEngine.centerTarget(
            columnIndex: activeColumnIndex,
            columns: columns,
            viewport: viewport
        )
        animator.animateTo(target: centerTarget, omega: config.springOmega)
    }

    public func stackLeft() {
        guard activeColumnIndex > 0 else { return }
        if StripLayoutEngine.stack(
            sourceColIndex: activeColumnIndex,
            targetColIndex: activeColumnIndex - 1,
            columns: &columns
        ) {
            activeColumnIndex -= 1
            focusActiveWindow()
            updateLayout(animate: true)
        }
    }

    public func stackRight() {
        guard activeColumnIndex < columns.count - 1 else { return }
        if StripLayoutEngine.stack(
            sourceColIndex: activeColumnIndex,
            targetColIndex: activeColumnIndex + 1,
            columns: &columns
        ) {
            focusActiveWindow()
            updateLayout(animate: true)
        }
    }

    public func unstack(toRight: Bool) {
        if StripLayoutEngine.unstack(
            columnIndex: activeColumnIndex,
            popToRight: toRight,
            columns: &columns
        ) {
            if toRight { activeColumnIndex += 1 }
            focusActiveWindow()
            updateLayout(animate: true)
        }
    }

    public func toggleTabbed(columnIndex: Int? = nil) {
        let idx = columnIndex ?? activeColumnIndex
        guard columns.indices.contains(idx) else { return }
        columns[idx].isTabbed.toggle()
        updateLayout(animate: true)
    }

    public func togglePin(columnIndex: Int? = nil) {
        let idx = columnIndex ?? activeColumnIndex
        guard columns.indices.contains(idx) else { return }
        columns[idx].isPinned.toggle()
        updateLayout(animate: true)
    }

    public func stack(direction: String) {
        if direction == "left" {
            stackLeft()
        } else {
            stackRight()
        }
    }

    public func jumpToColumn(index: Int) {
        guard index >= 0 && index < columns.count else { return }
        activeColumnIndex = index
        focusActiveWindow()
        scrollToColumn(index, animated: true)
    }

    /// Smoothly spring-scrolls to the agent window currently requesting human approval.
    public func jumpToApproval() {
        guard let approvalIdx = StripLayoutEngine.findApprovalColumnIndex(columns: columns) else {
            return
        }
        activeColumnIndex = approvalIdx
        focusActiveWindow()
        let target = StripLayoutEngine.centerTarget(
            columnIndex: approvalIdx,
            columns: columns,
            viewport: viewport
        )
        animator.animateTo(target: target, omega: config.springOmega)
    }

    public func focusColumn(direction: String) {
        if direction == "left" {
            focusLeft()
        } else {
            focusRight()
        }
    }

    public func centerActiveColumn() {
        centerCurrentColumn()
    }

    public func cycleWidth(mode: String = "cycle") {
        if mode == "full" {
            toggleFullWidth()
        } else {
            cycleWidth()
        }
    }

    public func jumpToApprovalAgent() {
        jumpToApproval()
    }

    public func applyInteractiveScroll(_ offset: Double) {
        let maxScroll = layoutResult.maxScrollOffset
        let clamped = DampedSpring.rubberBand(
            offset: offset,
            maxOffset: maxScroll,
            screenWidth: viewport.screenWidth
        )
        animator.applyInteractiveOffset(clamped)
    }

    public func settleInteractiveScroll() {
        let maxScroll = layoutResult.maxScrollOffset
        let nearestTarget = max(0.0, min(viewport.scrollOffset, maxScroll))
        animator.animateTo(target: nearestTarget, omega: config.springOmega)
    }

    private func scrollToColumn(_ index: Int, animated: Bool) {
        let target = StripLayoutEngine.revealTarget(
            columnIndex: index,
            columns: columns,
            viewport: viewport
        )
        if animated {
            animator.animateTo(target: target, omega: config.springOmega)
        } else {
            animator.snapTo(target: target)
        }
    }

    private func focusActiveWindow() {
        guard columns.indices.contains(activeColumnIndex),
            let win = columns[activeColumnIndex].activeWindow
        else { return }
        registry.focusWindow(windowID: win.id, pid: win.pid)
    }
}
