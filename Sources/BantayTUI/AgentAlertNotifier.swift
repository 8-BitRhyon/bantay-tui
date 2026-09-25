import Foundation
import UserNotifications

/// Push notifications for agent-state events requiring attention.
enum AgentAlertNotifier {
    /// Redact a title for push: titles carry tool commands / file paths
    /// (Claude hook sends `tool_input.command`), which shouldn't be stored
    /// on a third-party ntfy server in full. Truncate and strip $HOME.
    static func redactedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        var t = title.replacingOccurrences(
            of: NSHomeDirectory(), with: "~", options: [.anchored])
        if t.count > 120 {
            t = String(t.prefix(120)) + "…"
        }
        return t
    }

    /// ntfy message body for an agent event (title redacted), optionally carrying per-agent roster.
    static func messageBody(
        source: String,
        kind: AgentEventKind,
        title: String?,
        roster: [AgentSnapshot]? = nil
    ) -> String {
        let safeTitle = redactedTitle(title)
        var headline: String
        switch kind {
        case .accessRequest, .waiting:
            headline = "\(source) needs your approval\(safeTitle.map { ": \($0)" } ?? "")"
        case .failed:
            headline = "\(source) failed\(safeTitle.map { ": \($0)" } ?? "")"
        case .completed:
            headline = "\(source) finished\(safeTitle.map { ": \($0)" } ?? "")"
        default:
            headline = "\(source): \(kind.label)\(safeTitle.map { ": \($0)" } ?? "")"
        }

        guard let roster, !roster.isEmpty else {
            return headline
        }

        var lines: [String] = ["", "Active agents (\(roster.count)):"]
        for agent in roster {
            let glyph: String
            switch agent.kind {
            case .accessRequest, .waiting: glyph = "🟡"
            case .failed, .cancelled: glyph = "🔴"
            case .completed: glyph = "🔵"
            case .progress, .started: glyph = "🟢"
            default: glyph = agent.isWorking ? "🟢" : "⚪️"
            }

            let projectPart: String
            if let ctx = agent.projectContext {
                if let branch = ctx.branch {
                    projectPart = " (\(ctx.project) · \(branch))"
                } else {
                    projectPart = " (\(ctx.project))"
                }
            } else if let cwd = agent.cwd, !cwd.isEmpty {
                projectPart = " (\(URL(fileURLWithPath: cwd).lastPathComponent))"
            } else {
                projectPart = ""
            }

            let desc = redactedTitle(agent.title ?? agent.message) ?? agent.kind.label
            lines.append("• \(agent.source)\(projectPart): \(glyph) \(desc)")
        }

        return headline + "\n" + lines.joined(separator: "\n")
    }

    /// Builds the ntfy Actions header string for actionable remote notification buttons.
    static func ntfyActions(
        paneId: String?,
        choices: [String]?,
        callbackBase: String,
        token: String
    ) -> String? {
        guard let paneId, !paneId.isEmpty else { return nil }
        let base = callbackBase.hasSuffix("/") ? String(callbackBase.dropLast()) : callbackBase
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard
            let encodedPane = paneId.addingPercentEncoding(withAllowedCharacters: allowed),
            let encodedToken = token.addingPercentEncoding(withAllowedCharacters: allowed)
        else {
            return nil
        }

        var actions: [String] = []

        if let choices, !choices.isEmpty {
            // Show up to 2 numbered choices plus Deny (keeps <= 3 action buttons for ntfy mobile)
            for (idx, choiceText) in choices.prefix(2).enumerated() {
                let choiceNum = idx + 1
                let label = "Choice \(choiceNum): \(choiceText.prefix(20))"
                let url =
                    "\(base)/choice?token=\(encodedToken)&pane=\(encodedPane)&choice=\(choiceNum)"
                actions.append("action=http, label=\(label), url=\(url), method=POST, clear=true")
            }
            let denyURL = "\(base)/deny?token=\(encodedToken)&pane=\(encodedPane)"
            actions.append("action=http, label=Deny, url=\(denyURL), method=POST, clear=true")
        } else {
            let approveURL = "\(base)/approve?token=\(encodedToken)&pane=\(encodedPane)"
            let denyURL = "\(base)/deny?token=\(encodedToken)&pane=\(encodedPane)"
            actions.append(
                "action=http, label=Approve, url=\(approveURL), method=POST, clear=true")
            actions.append("action=http, label=Deny, url=\(denyURL), method=POST, clear=true")
        }

        return actions.isEmpty ? nil : actions.joined(separator: "; ")
    }

    /// ntfy topic / server from config; nil when push is disabled.
    @MainActor
    static func target() -> (topic: String, server: String)? {
        let config = NotchHUDConfig.shared
        guard config.ntfyEnabled else { return nil }
        return (config.ntfyTopic, config.ntfyServer)
    }

    /// Push a notification for `kind`, if a topic is configured and the kind
    /// is worth pinging for (blocked/approval/failed/completed). Honors quiet
    /// hours for sound-bearing events; the push itself is non-blocking.
    @MainActor
    static func notify(
        source: String,
        kind: AgentEventKind,
        title: String?,
        paneId: String? = nil,
        choices: [String]? = nil,
        cwd: String? = nil,
        sessionPath: String? = nil,
        roster: [AgentSnapshot]? = nil
    ) {
        // Only kinds worth a phone ping — progress/started/idle would turn
        // a busy agent into a notification stream.
        guard
            kind == .accessRequest || kind == .waiting
                || kind == .failed || kind == .completed
        else {
            return
        }
        if kind == .accessRequest || kind == .waiting {
            ApprovalNotificationController.shared.postApproval(
                source: source, paneId: paneId, title: title, choices: choices,
                cwd: cwd, sessionPath: sessionPath)
        } else if kind == .completed {
            ApprovalNotificationController.shared.postCompletion(
                source: source, paneId: paneId, title: title, cwd: cwd,
                sessionPath: sessionPath)
        } else if kind == .failed {
            ApprovalNotificationController.shared.postFailure(
                source: source, paneId: paneId, title: title, cwd: cwd)
        }
        guard let (topic, server) = target() else { return }
        let body = messageBody(source: source, kind: kind, title: title, roster: roster)
        let serverURL = server.hasSuffix("/") ? String(server.dropLast()) : server
        var urlString = "\(serverURL)/\(topic)"
        if let paneId, !paneId.isEmpty {
            urlString += "?x-target=\(paneId)"
        }
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue("Bantay-TUI", forHTTPHeaderField: "Title")
        request.setValue(
            kind == .accessRequest || kind == .waiting ? "high" : "default",
            forHTTPHeaderField: "Priority")
        if kind == .accessRequest || kind == .waiting {
            request.setValue("rotating_light", forHTTPHeaderField: "Tags")
            let callbackBase = NotchHUDConfig.shared.effectiveCallbackURL
            let token = NotchHUDConfig.shared.ingestToken
            if let actionsHeader = ntfyActions(
                paneId: paneId, choices: choices, callbackBase: callbackBase, token: token
            ) {
                request.setValue(actionsHeader, forHTTPHeaderField: "Actions")
            }
        } else if kind == .failed {
            request.setValue("warning", forHTTPHeaderField: "Tags")
        } else {
            request.setValue("white_check_mark", forHTTPHeaderField: "Tags")
        }
        request.httpBody = Data(body.utf8)
        Task.detached(priority: .utility) {
            do {
                _ = try await URLSession.shared.data(for: request)
            } catch {
                // Best-effort: a failed push is never fatal.
            }
        }
    }

    @MainActor
    static func notify(title: String, message: String) {
        guard ApprovalNotificationController.hasBundleProxy else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
