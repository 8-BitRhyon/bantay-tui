import Foundation
import UserNotifications

/// Posts interactive approval notifications via UNUserNotificationCenter.
@MainActor
final class ApprovalNotificationController: NSObject,
    @preconcurrency UNUserNotificationCenterDelegate
{
    static let shared = ApprovalNotificationController()

    static let categoryID = "BANTAY_APPROVAL"
    static let choiceCategoryID = "BANTAY_APPROVAL_CHOICE"
    static let questionCategoryID = "BANTAY_QUESTION"
    static let multiCategoryID = "BANTAY_MULTI"
    static let reviewCategoryID = "BANTAY_REVIEW"
    static let completedCategoryID = "BANTAY_COMPLETED"
    static let failedCategoryID = "BANTAY_FAILED"

    static let approveActionID = "BANTAY_APPROVE"
    static let denyActionID = "BANTAY_DENY"
    static let answerActionID = "BANTAY_ANSWER"
    static let choiceActionIDPrefix = "BANTAY_CHOICE_"
    static let viewSessionActionID = "BANTAY_VIEW_SESSION"
    static let focusActionID = "BANTAY_FOCUS"
    static let dismissActionID = "BANTAY_DISMISS"

    /// Fixed number of numbered choice actions registered up front so action
    /// sets never go stale across posts (the category is global).
    private static let maxChoiceActions = 4
    /// Banner ceiling: a category may register four actions total. Question
    /// banners spend one on Answer, permission banners two on Approve/Deny.
    private static let questionChoiceCount = 3
    private static let permissionChoiceCount = 2

    private override init() {
        super.init()
        installed = false
    }

    private var installed = false

    /// Checks if the current process is running inside an application bundle.
    nonisolated static var hasBundleProxy: Bool {
        guard let id = Bundle.main.bundleIdentifier, !id.isEmpty else { return false }
        return Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private var hasBundleProxy: Bool {
        Self.hasBundleProxy
    }

    /// Register the approval categories + install the delegate. Idempotent.
    func install() {
        guard !installed, hasBundleProxy else { return }
        installed = true
        let approve = UNNotificationAction(
            identifier: Self.approveActionID, title: "Approve",
            options: [.authenticationRequired])
        let deny = UNNotificationAction(
            identifier: Self.denyActionID, title: "Deny",
            options: [.destructive, .authenticationRequired])
        var choiceActions = [approve, deny]
        for index in 0..<Self.permissionChoiceCount {
            choiceActions.append(
                UNNotificationAction(
                    identifier: Self.choiceActionIDPrefix + String(index),
                    title: "Choice \(index + 1)",
                    options: [.authenticationRequired]))
        }
        let answer = UNNotificationAction(
            identifier: Self.answerActionID, title: "Answer",
            options: [.foreground])
        // Questions never offer Approve/Deny: answering directly is the only
        // safe quick action, plus Answer to open the full question.
        var questionActions = [answer]
        for index in 0..<Self.questionChoiceCount {
            questionActions.append(
                UNNotificationAction(
                    identifier: Self.choiceActionIDPrefix + String(index),
                    title: "Choice \(index + 1)",
                    options: [.authenticationRequired]))
        }
        let viewSession = UNNotificationAction(
            identifier: Self.viewSessionActionID, title: "View in Browser",
            options: [.foreground])
        let dismiss = UNNotificationAction(
            identifier: Self.dismissActionID, title: "Dismiss",
            options: [])
        let focus = UNNotificationAction(
            identifier: Self.focusActionID, title: "Focus Agent",
            options: [.foreground])

        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID, actions: [approve, deny],
                intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: Self.choiceCategoryID, actions: choiceActions,
                intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: Self.questionCategoryID, actions: questionActions,
                intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: Self.multiCategoryID, actions: [answer, focus],
                intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: Self.reviewCategoryID, actions: [focus, dismiss],
                intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: Self.completedCategoryID, actions: [viewSession, dismiss],
                intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: Self.failedCategoryID, actions: [focus, dismiss],
                intentIdentifiers: [], options: []),
        ])
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
            _, _ in
        }
    }

    /// Post an approval notification for a blocked event. Events carrying
    /// two or more choices are questions, not permissions: they get an
    /// Answer action and numbered choices, never Approve/Deny.
    /// Multi-select prompts cannot be answered from a banner (buttons have
    /// no toggle state, and one tap must never partial-answer a pick-several
    /// question), so they get Answer plus Focus and the body lists options.
    func postApproval(
        source: String, paneId: String?, title: String?, choices: [String]?,
        cwd: String? = nil, sessionPath: String? = nil, isMulti: Bool = false
    ) {
        guard let paneId, hasBundleProxy else { return }
        install()
        let content = UNMutableNotificationContent()
        let hasChoices = choices?.isEmpty == false
        let isQuestion = (choices?.count ?? 0) >= 2
        let concrete = isConcreteApprovalTitle(title)
        // Review-only panes never get Approve/Deny actions: without a
        // transport the buttons could only lie.
        let canRespond = ApprovalRouting.supportsDecision(
            paneId: paneId,
            inputSynthesisEnabled: StandaloneAgentDispatcher.enableInputSynthesis)
        let answerable = (concrete || hasChoices) && canRespond
        content.title =
            isMulti
            ? "\(source) has a multi-part question"
            : (isQuestion
                ? "\(source) has a question"
                : (answerable ? "\(source) needs approval" : "\(source) is waiting"))
        content.body =
            answerable
            ? approvalBody(title: title, choices: choices)
            : "Open Bantay to review the request before deciding."
        content.sound = .default
        var category =
            isMulti
            ? Self.multiCategoryID
            : (isQuestion
                ? Self.questionCategoryID
                : (hasChoices
                    ? Self.choiceCategoryID : (concrete ? Self.categoryID : Self.reviewCategoryID)))
        if !canRespond
            && (category == Self.categoryID || category == Self.choiceCategoryID)
        {
            category = Self.reviewCategoryID
        }
        content.categoryIdentifier = category
        var info: [String: String] = ["paneId": paneId, "source": source]
        if let cwd { info["cwd"] = cwd }
        if let sessionPath { info["sessionPath"] = sessionPath }
        content.userInfo = info

        let request = UNNotificationRequest(
            identifier: paneId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("approval-notify: %@ failed: %@", paneId, String(describing: error))
            }
        }
    }

    /// A notification may offer Approve and Deny only when it names the exact
    /// request. Status-only blocked heartbeats get Review/Focus actions.
    private func isConcreteApprovalTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let generic: Set<String> = [
            "blocked", "waiting", "needs input", "needs approval",
            "agent requires input", "approval required", "permission required",
        ]
        return !generic.contains(trimmed.lowercased())
    }

    /// Post a completion notification with actionable "View in Browser" button.
    func postCompletion(
        source: String, paneId: String?, title: String?, cwd: String? = nil,
        sessionPath: String? = nil
    ) {
        guard hasBundleProxy else { return }
        install()
        let content = UNMutableNotificationContent()
        content.title = "\(source) finished"
        content.body = title ?? "Agent completed work."
        content.sound = .default
        content.categoryIdentifier = Self.completedCategoryID
        var info: [String: String] = ["source": source]
        if let paneId { info["paneId"] = paneId }
        if let cwd { info["cwd"] = cwd }
        if let sessionPath { info["sessionPath"] = sessionPath }
        content.userInfo = info

        let identifier = paneId ?? ("bantay-done-" + UUID().uuidString)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("approval-notify: completion failed: %@", String(describing: error))
            }
        }
    }

    /// Post a failure notification with actionable "Focus Agent" button.
    func postFailure(
        source: String, paneId: String?, title: String?, cwd: String? = nil
    ) {
        guard hasBundleProxy else { return }
        install()
        let content = UNMutableNotificationContent()
        content.title = "\(source) failed"
        content.body = title ?? "Agent encountered an error."
        content.sound = .default
        content.categoryIdentifier = Self.failedCategoryID
        var info: [String: String] = ["source": source]
        if let paneId { info["paneId"] = paneId }
        if let cwd { info["cwd"] = cwd }
        content.userInfo = info

        let identifier = paneId ?? ("bantay-fail-" + UUID().uuidString)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("approval-notify: failure failed: %@", String(describing: error))
            }
        }
    }

    /// Post a system notification alert (e.g. budget exceeded or high burn rate).
    func postAlert(title: String, subtitle: String, soundName: String?) {
        guard hasBundleProxy else { return }
        install()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = subtitle
        if let soundName, !soundName.isEmpty {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName))
        } else {
            content.sound = .default
        }
        let identifier = "bantay-alert-" + UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("approval-notify: alert failed: %@", String(describing: error))
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
    func approvalBody(title: String?, choices: [String]?) -> String {
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
        Task { @MainActor in
            defer { completionHandler() }
            let userInfo = response.notification.request.content.userInfo
            let paneId = userInfo["paneId"] as? String
            let source = userInfo["source"] as? String ?? "Agent"
            let cwd = userInfo["cwd"] as? String
            let sessionPath = userInfo["sessionPath"] as? String

            switch response.actionIdentifier {
            case Self.approveActionID:
                guard let paneId else { return }
                let manager = AgentEventManager.shared
                guard !manager.isResolving(paneId: paneId) else { return }
                await manager.approve(paneId: paneId)
            case Self.denyActionID:
                guard let paneId else { return }
                let manager = AgentEventManager.shared
                guard !manager.isResolving(paneId: paneId) else { return }
                await manager.deny(paneId: paneId)
            case Self.answerActionID:
                // Questions open where they can be answered: focus the exact
                // terminal pane and expand the inbox. Never resolves anything.
                if let paneId, paneId.hasPrefix("standalone:") {
                    let agent = AgentEventManager.shared.agents.first { $0.paneId == paneId }
                    TerminalFocusser.focusStandalone(source: source, cwd: cwd ?? agent?.cwd)
                } else if let paneId {
                    let manager = AgentEventManager.shared
                    manager.performAction(paneId: paneId) { $0.focusPane(paneId: paneId) }
                }
                NotificationCenter.default.post(name: .notchExpandRequested, object: nil)
            case Self.viewSessionActionID:
                let slug = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? source
                RichSessionViewer.openInBrowser(
                    agentName: source,
                    projectSlug: slug,
                    cwd: cwd,
                    isWorking: false,
                    sessionPath: sessionPath
                )
            case Self.focusActionID, UNNotificationDefaultActionIdentifier:
                if let paneId, paneId.hasPrefix("standalone:") {
                    let agent = AgentEventManager.shared.agents.first { $0.paneId == paneId }
                    TerminalFocusser.focusStandalone(source: source, cwd: cwd ?? agent?.cwd)
                } else if let paneId {
                    let manager = AgentEventManager.shared
                    manager.performAction(paneId: paneId) { $0.focusPane(paneId: paneId) }
                } else {
                    TerminalFocusser.focusStandalone(source: source, cwd: cwd)
                }
            case Self.dismissActionID:
                break
            default:
                if response.actionIdentifier.hasPrefix(Self.choiceActionIDPrefix) {
                    guard let paneId else { return }
                    let manager = AgentEventManager.shared
                    guard !manager.isResolving(paneId: paneId) else { return }
                    let indexString = response.actionIdentifier.dropFirst(
                        Self.choiceActionIDPrefix.count)
                    guard let index = Int(indexString) else { return }
                    let number = IslandMetrics.ApprovalControls.optionNumber(forIndex: index)
                    await manager.approveChoice(paneId: paneId, choice: number)
                }
            }
        }
    }
}
