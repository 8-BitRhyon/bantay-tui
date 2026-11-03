import AppKit
import ApplicationServices
import Foundation
import UserNotifications

/// One system grant, named by what it unlocks. Permissions are asked
/// per capability (the Hex split): hearing global keys, sending keys,
/// and posting banners are three different grants, and the Settings
/// surface says which feature each one enables instead of asking for
/// "permissions" in the abstract.
enum PermissionCapability: String, CaseIterable, Identifiable, Sendable {
    case accessibility
    case inputMonitoring
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .notifications: return "Notifications"
        }
    }

    /// What the user gets for granting this, in one line.
    var detail: String {
        switch self {
        case .accessibility:
            return "Answer agents, focus inputs, and tile windows."
        case .inputMonitoring:
            return "Hear the global hotkeys (approve, deny, snooze)."
        case .notifications:
            return "Post banners when the island is hidden or locked."
        }
    }

    var settingsURLString: String {
        switch self {
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .notifications:
            return "x-apple.systempreferences:com.apple.preference.notifications"
        }
    }
}

/// Live grant checks and requests. Every check reads the current TCC
/// state, so Settings can re-poll while open and a grant lands without
/// restarting the app. Nothing here prompts on its own: prompts fire
/// only from the explicit Settings buttons.
enum Permissions {
    static func isGranted(_ capability: PermissionCapability) async -> Bool {
        switch capability {
        case .accessibility:
            return AXIsProcessTrusted()
        case .inputMonitoring:
            return CGPreflightListenEventAccess()
        case .notifications:
            // UNUserNotificationCenter crashes outside an app bundle
            // (bundleProxyForCurrentProcess is nil), so bare binaries
            // report ungranted instead of touching it.
            guard Bundle.main.bundleIdentifier != nil,
                Bundle.main.bundleURL.pathExtension.lowercased() == "app"
            else { return false }
            let settings = await UNUserNotificationCenter.current()
                .notificationSettings()
            return settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        }
    }

    /// Ask the system for the grant. Accessibility uses the one-shot
    /// system prompt; Input Monitoring registers the app in the list
    /// (the user still flips the switch in Settings); Notifications
    /// requests banner authorization.
    /// The system Accessibility prompt fires once per process: on a
    /// signed build the nag loop is worse than the missing grant.
    nonisolated(unsafe) private static var didPromptForAccessibility = false

    @MainActor
    static func request(_ capability: PermissionCapability) async {
        switch capability {
        case .accessibility:
            guard !didPromptForAccessibility else {
                openSettings(for: capability)
                return
            }
            didPromptForAccessibility = true
            let options =
                ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
            openSettings(for: capability)
        case .notifications:
            guard Bundle.main.bundleIdentifier != nil,
                Bundle.main.bundleURL.pathExtension.lowercased() == "app"
            else { return }
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
    }

    @MainActor
    static func openSettings(for capability: PermissionCapability) {
        guard let url = URL(string: capability.settingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }
}
