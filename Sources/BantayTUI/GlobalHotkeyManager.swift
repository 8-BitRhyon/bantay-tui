import AppKit
import Carbon
import Combine
import Foundation

@MainActor
public final class GlobalHotkeyManager: ObservableObject {
    public static let shared = GlobalHotkeyManager()

    @Published public private(set) var isRegistered: Bool = false

    private var eventMonitor: Any?

    private init() {
        registerGlobalHotkey()
    }

    public func registerGlobalHotkey() {
        unregisterGlobalHotkey()
        guard NotchHUDConfig.shared.globalHotkeyEnabled else { return }
        guard ApprovalNotificationController.hasBundleProxy else {
            isRegistered = false
            return
        }

        // Global monitor for Option+Space or Option+Option double press
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // Check Option+Space (keyCode 49, modifier option)
            if event.keyCode == 49 && event.modifierFlags.contains(.option) {
                Task { @MainActor in
                    NotificationCenter.default.post(name: .notchGlobalHotkeyTriggered, object: nil)
                }
            }
        }
        isRegistered = (eventMonitor != nil)
    }

    public func unregisterGlobalHotkey() {
        guard ApprovalNotificationController.hasBundleProxy else {
            eventMonitor = nil
            isRegistered = false
            return
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isRegistered = false
    }
}

extension Notification.Name {
    public static let notchGlobalHotkeyTriggered = Notification.Name("notchGlobalHotkeyTriggered")
}
