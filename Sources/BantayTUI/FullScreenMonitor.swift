import AppKit
import ApplicationServices
import Combine
import Foundation

/// Tracks whether the frontmost application is presenting a full-screen
/// window. `NSWindow.didEnterFullScreenNotification` only reports windows
/// owned by this process, so the monitor asks the frontmost app through
/// Accessibility and falls back to window bounds for apps that do not expose
/// the `AXFullScreen` attribute.
@MainActor
public final class FullScreenMonitor: ObservableObject {
    public static let shared = FullScreenMonitor()

    /// True while the app the user is working in has a full-screen window.
    @Published public private(set) var isFullScreen: Bool = false

    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var lastNonSelfState = false
    private var started = false

    private init() {}

    /// Starts polling and observing app/space changes. Safe to call twice.
    public func start() {
        guard !started else { return }
        started = true
        installObservers()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refreshNow()
    }

    /// Stops polling. The monitor stays usable and can be started again.
    public func stop() {
        guard started else { return }
        started = false
        pollTimer?.invalidate()
        pollTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Recomputes the state immediately on the main thread.
    public func refreshNow() {
        refreshTask?.cancel()
        refreshTask = nil
        let next = detect()
        guard next != isFullScreen else { return }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        fputs("[bantay] full-screen monitor: frontmost=\(front) fullScreen=\(next)\n", stderr)
        fflush(stderr)
        isFullScreen = next
    }

    /// Debounced refresh used after activation and Space transitions, where
    /// the WindowServer needs a moment to settle the new full-screen window.
    public func scheduleRefresh(after delay: TimeInterval = 0.15) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefresh(after: 0.1)
                }
            })
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefresh(after: 0.2)
                }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefresh(after: 0.3)
                }
            })
    }

    private func detect() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            return lastNonSelfState
        }

        // Non-activating panels can become key without changing the
        // frontmost app. When Bantay itself is frontmost, keep the last real
        // answer instead of treating the overlay as a normal app.
        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return lastNonSelfState
        }
        guard front.activationPolicy == .regular else {
            return lastNonSelfState
        }

        let detected = Self.detectFullScreen(pid: front.processIdentifier)
        lastNonSelfState = detected
        return detected
    }

    /// Returns true when the given process owns a full-screen window.
    /// Accessibility is authoritative when it answers; otherwise the window
    /// bounds heuristic catches apps that do not publish `AXFullScreen`.
    static func detectFullScreen(pid: pid_t) -> Bool {
        if AXIsProcessTrusted(), let axValue = axFullScreen(pid: pid) {
            return axValue
        }
        return windowCoversScreen(pid: pid)
    }

    private static func axFullScreen(pid: pid_t) -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)

        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard let window = copyElement(app, attribute as String) else { continue }
            if let value = copyBool(window, "AXFullScreen") {
                return value
            }
        }

        // Some apps publish the attribute only on the window list.
        guard let windows = copyElements(app, kAXWindowsAttribute as String) else {
            return nil
        }
        var supported = false
        for window in windows {
            guard let value = copyBool(window, "AXFullScreen") else { continue }
            if value { return true }
            supported = true
        }
        return supported ? false : nil
    }

    private static func windowCoversScreen(pid: pid_t) -> Bool {
        guard
            let raw = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else { return false }

        guard let primary = NSScreen.screens.first else { return false }
        let screens = NSScreen.screens.map { screen in
            IslandMetrics.FullScreenPolicy.cgScreenRect(
                appKitFrame: screen.frame,
                primaryMaxY: primary.frame.maxY
            )
        }

        for info in raw {
            guard
                let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                owner == pid,
                (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0 > 0.01,
                let bounds = info[kCGWindowBounds as String] as? [String: NSNumber]
            else { continue }

            let frame = CGRect(
                x: bounds["X"]?.doubleValue ?? 0,
                y: bounds["Y"]?.doubleValue ?? 0,
                width: bounds["Width"]?.doubleValue ?? 0,
                height: bounds["Height"]?.doubleValue ?? 0
            )
            if screens.contains(where: {
                IslandMetrics.FullScreenPolicy.coversScreen(
                    windowFrame: frame,
                    screenFrame: $0
                )
            }) {
                return true
            }
        }
        return false
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyElements(_ element: AXUIElement, _ attribute: String)
        -> [AXUIElement]?
    {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == CFArrayGetTypeID()
        else { return nil }
        return value as? [AXUIElement]
    }

    private static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return nil }
        return value as? Bool
    }
}
