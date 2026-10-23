import AppKit
import Carbon
import Combine
import Foundation

@MainActor
public final class GlobalHotkeyManager: ObservableObject {
    public static let shared = GlobalHotkeyManager()

    @Published public private(set) var isRegistered: Bool = false

    private init() {
        registerGlobalHotkey()
    }

    public func registerGlobalHotkey() {
        // Single-monitor rule: AppDelegate owns the only global hotkey
        // monitors. A second Option+Space monitor here used to double-toggle
        // the island, so this forwards instead of installing its own.
        AppDelegate.shared?.updateGlobalHotkeyMonitor()
        isRegistered = NotchHUDConfig.shared.globalHotkeyEnabled
    }

    public func unregisterGlobalHotkey() {
        isRegistered = false
    }
}

extension Notification.Name {
    public static let notchGlobalHotkeyTriggered = Notification.Name("notchGlobalHotkeyTriggered")
}
