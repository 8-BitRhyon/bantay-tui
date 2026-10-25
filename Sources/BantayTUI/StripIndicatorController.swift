import AppKit
import Combine
import SwiftUI

/// Hosts the strip indicator: a small frosted capsule that appears while the
/// strip is navigated, stays while Control-Option is held, and fades out on
/// its own. Mirrors ChainYourMac's indicator so the strip has a visible map
/// and a click/drag surface.
@MainActor
final class StripIndicatorController {
    static let shared = StripIndicatorController()

    static let autoHideSeconds = StripConfiguration.indicatorAutoHideSeconds
    static let panelHeight: CGFloat = 44

    private var panel: KeyablePanel?
    private var hosting: NSHostingView<StripIndicatorView>?
    private var hideTask: Task<Void, Never>?
    private var flagMonitor: Any?
    private var localFlagMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var isHolding = false
    private(set) var isVisible = false

    private init() {
        let manager = StripWindowManager.shared

        // Any navigation, reorder, or overview change re-shows the map.
        manager.$activeColumnIndex
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.flash() }
            .store(in: &cancellables)
        manager.$columns
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.flash() }
            .store(in: &cancellables)
        manager.$isOverviewMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.flash() }
            .store(in: &cancellables)

        // Control-Option is the strip modifier: holding it pins the map.
        flagMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            let held = event.modifierFlags.contains([.control, .option])
            Task { @MainActor in self?.setHolding(held) }
        }
        localFlagMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            let held = event.modifierFlags.contains([.control, .option])
            Task { @MainActor in self?.setHolding(held) }
            return event
        }

        FullScreenMonitor.shared.$isFullScreen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isFullScreen in
                if isFullScreen { self?.hide() }
            }
            .store(in: &cancellables)
    }

    /// Show briefly after a navigation step.
    func flash() {
        guard StripWindowManager.shared.config.isEnabled,
            StripWindowManager.shared.config.showStripIndicator,
            !StripWindowManager.shared.isFullScreen,
            !StripWindowManager.shared.columns.isEmpty
        else { return }
        show()
        scheduleHide(after: Self.autoHideSeconds)
    }

    private func setHolding(_ held: Bool) {
        guard held != isHolding else { return }
        isHolding = held
        if held {
            guard StripWindowManager.shared.config.isEnabled,
                StripWindowManager.shared.config.showStripIndicator,
                !StripWindowManager.shared.isFullScreen,
                !StripWindowManager.shared.columns.isEmpty
            else { return }
            hideTask?.cancel()
            hideTask = nil
            show()
        } else if isVisible {
            scheduleHide(after: 0.4)
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.isHolding else { return }
            self.hide()
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let screen = targetScreen() else { return }
        let maxWidth = min(max(screen.visibleFrame.width * 0.8, 240), 900)
        refreshContent(maxWidth: maxWidth)
        position(panel, on: screen)
        if !isVisible {
            NSLog("strip indicator: show columns=%d", StripWindowManager.shared.columns.count)
        }
        isVisible = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.14
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
    }

    private func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, isVisible else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.28
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isVisible else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar + 8
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        return panel
    }

    /// Rebuilds the hosted view so the tiles, active highlight, and widths
    /// always mirror the live strip, then sizes the panel to fit.
    private func refreshContent(maxWidth: CGFloat) {
        let manager = StripWindowManager.shared
        let view = StripIndicatorView(
            columns: manager.columns,
            activeColumnIndex: manager.activeColumnIndex,
            visibleWindowIDs: manager.layoutResult.visibleWindowIDs,
            maxWidth: maxWidth,
            onSelect: { index in
                manager.jumpToColumn(index: index)
                StripIndicatorController.shared.flash()
            },
            onReorder: { from, to in
                manager.reorderColumn(fromIndex: from, toIndex: to)
            })
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        panel?.contentView = hosting
        self.hosting = hosting
        panel?.setContentSize(
            NSSize(
                width: hosting.fittingSize.width,
                height: max(hosting.fittingSize.height, Self.panelHeight)))
    }

    /// The screen whose strip the user is driving, not the screen under the
    /// pointer: keyboard navigation happens on the active strip.
    private func targetScreen() -> NSScreen? {
        let viewport = StripWindowManager.shared.viewport
        return NSScreen.screens.first { screen in
            let frame = screen.frame
            return viewport.screenOriginX >= frame.minX
                && viewport.screenOriginX < frame.maxX
                && viewport.screenOriginY >= frame.minY
                && viewport.screenOriginY < frame.maxY
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func position(_ panel: KeyablePanel, on screen: NSScreen) {
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let width = min(size.width, max(visible.width - 80, 240))
        panel.setFrame(
            NSRect(
                x: visible.midX - width / 2,
                y: visible.maxY - size.height - 10,
                width: width,
                height: size.height),
            display: true)
    }
}
