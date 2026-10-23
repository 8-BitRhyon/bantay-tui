import AppKit
import Combine
import SwiftUI

/// Bottom-center spatial HUD for Desktop strip control. Window-only: no
/// agent rows, approvals, tasks, or utilities. Mutually exclusive with the
/// expanded Agents notch panel.
@MainActor
final class DesktopHUDController: ObservableObject {
    static let shared = DesktopHUDController()

    static let panelWidth: CGFloat = 720
    static let panelHeight: CGFloat = 168
    static let bottomMargin: CGFloat = 24
    static let autoHideDelay: TimeInterval = 1.8

    @Published private(set) var isVisible = false
    @Published private(set) var windowCount = 0
    @Published var isPinned: Bool {
        didSet { UserDefaults.standard.set(isPinned, forKey: "desktopHUDPinned") }
    }

    private var panel: KeyablePanel?
    private var hideTask: Task<Void, Never>?
    private var fullScreenCancellable: AnyCancellable?
    private var columnsCancellable: AnyCancellable?

    init() {
        isPinned = UserDefaults.standard.bool(forKey: "desktopHUDPinned")
        refreshWindowCount(StripWindowManager.shared.columns)
        fullScreenCancellable = FullScreenMonitor.shared.$isFullScreen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isFullScreen in
                guard let self else { return }
                Task { @MainActor in
                    if isFullScreen { self.hide() }
                }
            }
        columnsCancellable = StripWindowManager.shared.$columns
            .receive(on: DispatchQueue.main)
            .sink { [weak self] columns in
                guard let self else { return }
                Task { @MainActor in
                    self.refreshWindowCount(columns)
                }
            }
    }

    private func refreshWindowCount(_ columns: [StripColumn]) {
        let count = columns.reduce(0) { $0 + $1.windows.count }
        if count != windowCount { windowCount = count }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let strip = StripWindowManager.shared
        guard strip.config.isEnabled else {
            AppDelegate.showSettings()
            return
        }
        guard !strip.isFullScreen else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        NotificationCenter.default.post(name: .notchCollapseRequested, object: nil)
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        isVisible = false
    }

    /// Pointer hover tracking from the HUD view. Leaving the HUD starts the
    /// auto-hide countdown unless the user pinned it open.
    func noteHover(_ hovering: Bool) {
        hideTask?.cancel()
        hideTask = nil
        guard !hovering, !isPinned, isVisible else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoHideDelay))
            guard let self, !Task.isCancelled else { return }
            if !self.isPinned { self.hide() }
        }
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar + 7
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: DesktopHUDView())
        return panel
    }

    private func position(_ panel: KeyablePanel) {
        let mouse = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let width = min(Self.panelWidth, max(visible.width - 48, 320))
        panel.setFrame(
            NSRect(
                x: visible.midX - width / 2,
                y: visible.minY + Self.bottomMargin,
                width: width,
                height: Self.panelHeight),
            display: true)
    }
}
