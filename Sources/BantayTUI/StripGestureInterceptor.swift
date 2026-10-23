import AppKit
import Carbon
import Foundation

/// Intercepts global keyboard shortcuts and trackpad gestures for the strip canvas.
@MainActor
public final class StripGestureInterceptor {
    public static let shared = StripGestureInterceptor()

    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var isTrackingScroll: Bool = false

    private init() {}

    /// Starts monitoring for strip hotkeys and gestures.
    public func start() {
        stop()

        // 1. Global Key Down Monitor
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyEvent(event)
            }
        }

        // 2. Trackpad / Scroll Wheel Monitor
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            Task { @MainActor in
                self?.handleScrollEvent(event)
            }
        }
    }

    /// Stops monitoring.
    public func stop() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard StripWindowManager.shared.config.isEnabled else { return }
        guard StripWindowManager.shared.config.hotkeysEnabled else { return }

        // Must hold Control + Option (⌃⌥)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isControlOption = flags.contains(.control) && flags.contains(.option)
        guard isControlOption else { return }

        let isShift = flags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let keyCode = event.keyCode

        // Left Arrow (123), Right Arrow (124)
        if keyCode == 123 || chars == "h" {
            if isShift {
                StripWindowManager.shared.moveLeft()
            } else {
                StripWindowManager.shared.focusLeft()
            }
            return
        }

        if keyCode == 124 || chars == "l" {
            if isShift {
                StripWindowManager.shared.moveRight()
            } else {
                StripWindowManager.shared.focusRight()
            }
            return
        }

        // Up/Down cycles the windows inside the active column.
        if keyCode == 126 {
            StripWindowManager.shared.focusPreviousWindow()
            return
        }
        if keyCode == 125 {
            StripWindowManager.shared.focusNextWindow()
            return
        }

        // Home/End jumps to the first/last column.
        if keyCode == 115 {
            StripWindowManager.shared.focusFirstColumn()
            return
        }
        if keyCode == 119 {
            StripWindowManager.shared.focusLastColumn()
            return
        }

        switch chars {
        case "r":
            StripWindowManager.shared.cycleWidth()
        case "f":
            StripWindowManager.shared.toggleFullWidth()
        case "c":
            StripWindowManager.shared.centerCurrentColumn()
        case "m":
            StripWindowManager.shared.autoChainCurrentProject(
                slug: StripWindowManager.shared.currentProjectSlug())
        case "a":
            StripWindowManager.shared.jumpToApproval()
        case "p":
            StripWindowManager.shared.togglePin()
        case "]":
            if isShift {
                StripWindowManager.shared.unstack(toRight: true)
            } else {
                StripWindowManager.shared.stackRight()
            }
        case "[":
            if isShift {
                StripWindowManager.shared.unstack(toRight: false)
            } else {
                StripWindowManager.shared.stackLeft()
            }
        case "t":
            if isShift {
                StripWindowManager.shared.toggleTabbed()
            }
        case "1"..."9":
            if let digit = Int(chars) {
                StripWindowManager.shared.jumpToColumn(index: digit - 1)
            }
        default:
            break
        }
    }

    private func handleScrollEvent(_ event: NSEvent) {
        guard StripWindowManager.shared.config.isEnabled,
            !StripWindowManager.shared.isFullScreen
        else { return }

        // Trigger on horizontal trackpad swipe with ⌃⌥ or momentum scroll
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasModifiers = flags.contains(.control) && flags.contains(.option)

        let deltaX = event.scrollingDeltaX
        guard abs(deltaX) > 0.5 else { return }

        if hasModifiers || event.hasPreciseScrollingDeltas {
            if event.phase == .began {
                isTrackingScroll = true
            } else if event.phase == .changed {
                let current = StripWindowManager.shared.viewport.scrollOffset
                // Invert delta for natural trackpad scrolling
                let newOffset = current - Double(deltaX)
                StripWindowManager.shared.applyInteractiveScroll(newOffset)
            } else if event.phase == .ended || event.phase == .cancelled {
                isTrackingScroll = false
                StripWindowManager.shared.settleInteractiveScroll()
            }
        }
    }
}
