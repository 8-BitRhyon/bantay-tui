import Foundation
import UserNotifications

/// Notification Center approval surface (Phase A A4): when an agent blocks,
/// post a notification with Approve/Deny (or numbered choices) actions so an
/// approval can be answered without touching the island or the terminal.
///
/// One shared instance. Registration is deferred to the first post because
/// UNUserNotificationCenter requires a bundle proxy, which a bare binary
/// launched from Application Support doesn't have at startup — registering
/// too early crashes. The actions map to the same
/// `AgentEventManager.performAction(paneId:)` path the inline roster controls
/// use.
@MainActor
final class ApprovalNotificationController: NSObject,
    @preconcurrency UNUserNotificationCenterDelegate
{
    static let shared = ApprovalNotificationController()

    static let categoryID = "BANTAY_APPROVAL"
    static let choiceCategoryID = "BANTAY_APPROVAL_CHOICE"
    private static let approveActionID = "BANTAY_APPROVE"
    private static let denyActionID = "BANTAY_DENY"
    private static let choiceActionIDPrefix = "BANTAY_CHOICE_"
    /// Fixed number of numbered choice actions registered up front so action
    /// sets never go stale across posts (the category is global).
    private static let maxChoiceActions = 4

    private override init() {
        super.init()
        installed = false
    }

    private var installed = false

    /// Whether this process can talk to UNUserNotificationCenter. A bare
    /// binary launched from Application Support (the installed layout) does not
    /// have an .app bundle proxy registered with macOS LaunchServices. Any call
    /// to UNUserNotificationCenter.current() in a bare binary crashes the process
    /// with `NSInternalInconsistencyException: bundleProxyForCurrentProcess is nil`.
    static var hasBundleProxy: Bool {
        guard let id = Bundle.main.bundleIdentifier, !id.isEmpty else { return false }
        return Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private var hasBundleProxy: Bool {
        Self.hasBundleProxy
    }

    /// Register the approval categories + install the delegate. Idempotent.
    /// TWO categories: plain yes/no (Approve/Deny only) and choice (numbered
    /// buttons), so a yes/no prompt never shows misleading numbered buttons.
    func install() {
        guard !installed, hasBundleProxy else { return }
        installed = true
        let approve = UNNotificationAction(
            identifier: Self.approveActionID, title: "Approve",
            options: [.authenticationRequired, .foreground])
        let deny = UNNotificationAction(
            identifier: Self.denyActionID, title: "Deny",
            options: [.destructive, .authenticationRequired, .foreground])
        var choiceActions = [approve, deny]
        for index in 0..<Self.maxChoiceActions {
            choiceActions.append(
                UNNotificationAction(
                    identifier: Self.choiceActionIDPrefix + String(index),
                    title: "\(index + 1)…",
                    options: [.authenticationRequired, .foreground]))
        }
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID, actions: [approve, deny],
                intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: Self.choiceCategoryID, actions: choiceActions,
                intentIdentifiers: [], options: []),
        ])
        UNUserNotificationCenter.current().delegate = self
    }

    /// Post an approval notification for a blocked event. The notification
    /// identifier is the pane id so re-posts replace the old one; the choice
    /// titles are carried in the body so the numbered buttons have context.
    func postApproval(
        source: String, paneId: String?, title: String?, choices: [String]?
    ) {
        guard let paneId, hasBundleProxy else { return }
        install()
        let content = UNMutableNotificationContent()
        content.title = "\(source) needs approval"
        content.body = approvalBody(title: title, choices: choices)
        content.sound = .default
        let hasChoices = choices.map { !$0.isEmpty } ?? false
        content.categoryIdentifier = hasChoices ? Self.choiceCategoryID : Self.categoryID
        content.userInfo = ["paneId": paneId]

        let request = UNNotificationRequest(
            identifier: paneId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("approval-notify: %@ failed: %@", paneId, String(describing: error))
            }
        }
    }

    /// Remove any pending + delivered notification for a pane that stopped
    /// being blocked, so a stale Approve/Deny can't inject a keypress into a
    /// pane that has moved on.
    func removeForPane(_ paneId: String) {
        guard hasBundleProxy else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [paneId])
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [paneId])
    }

    /// Human body: the prompt plus the numbered choices (or a hint).
    private func approvalBody(title: String?, choices: [String]?) -> String {
        var body = title ?? "Approve or deny the request."
        if let choices, !choices.isEmpty {
            let shown = choices.prefix(Self.maxChoiceActions)
            body +=
                "\n"
                + shown.enumerated().map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            if choices.count > Self.maxChoiceActions {
                body += "\n+\(choices.count - Self.maxChoiceActions) more"
            }
        }
        return body
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Keep the notification banner on screen while the island is visible.
    /// Sound respects the same alert gates as the island (quiet hours +
    /// master alert switch) so the phone isn't louder than the Mac.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let config = NotchHUDConfig.shared
        let withSound =
            config.enableAgentAlerts && !config.isInQuietHours()
        completionHandler(withSound ? [.banner, .sound] : [.banner])
    }

    /// Route an action button tap to the same approval path the island uses.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Hop (not assumeIsolated): the SDK doesn't guarantee main-thread
        // delivery, and assumeIsolated would trap the process if it ever
        // arrives off-main. Always complete — never stall the delegate.
        Task { @MainActor in
            defer { completionHandler() }
            guard
                let paneId = response.notification.request.content.userInfo["paneId"]
                    as? String
            else { return }
            let manager = AgentEventManager.shared
            // Never double-fire: if this pane's approval is already being
            // resolved (island / hotkey / another tap), drop the action.
            guard !manager.isResolving(paneId: paneId) else { return }
            switch response.actionIdentifier {
            case Self.approveActionID:
                manager.performAction(paneId: paneId) { $0.approve(paneId: paneId) }
            case Self.denyActionID:
                manager.performAction(paneId: paneId) { $0.deny(paneId: paneId) }
            case UNNotificationDefaultActionIdentifier:
                // Tapping the body = focus the pane, not approve.
                manager.performAction(paneId: paneId) { $0.focusPane(paneId: paneId) }
            default:
                if response.actionIdentifier.hasPrefix(Self.choiceActionIDPrefix) {
                    let indexString = response.actionIdentifier.dropFirst(
                        Self.choiceActionIDPrefix.count)
                    guard let index = Int(indexString) else { return }
                    let number = IslandMetrics.ApprovalControls.optionNumber(forIndex: index)
                    manager.performAction(paneId: paneId) {
                        $0.approveChoice(paneId: paneId, choice: number)
                    }
                }
            }
        }
    }
}
