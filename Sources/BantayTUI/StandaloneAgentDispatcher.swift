import AppKit
import CoreGraphics
import Foundation

public enum StandaloneAgentDispatcher {
    /// Controls whether UI automation (focus stealing, clipboard overwrites,
    /// haptic feedback, and synthesized keystrokes) is performed.
    /// Disabled during tests, test harnesses, or when suppressed.
    nonisolated(unsafe) public static var enableInputSynthesis: Bool = {
        if ProcessInfo.processInfo.environment["BANTAY_SUPPRESS_INPUT_SYNTHESIS"] != nil {
            return false
        }
        let proc = ProcessInfo.processInfo.processName.lowercased()
        if proc.contains("test") || proc.contains("logic-check") || proc.contains("xctest") {
            return false
        }
        if ProcessInfo.processInfo.arguments.contains(where: {
            let lower = $0.lowercased()
            return lower.contains("test") || lower.contains("xctest")
        }) {
            return false
        }
        if NSClassFromString("XCTestCase") != nil {
            return false
        }
        return true
    }()

    /// Injectable closure for keystroke synthesis.
    nonisolated(unsafe) public static var pasteAndReturnAction: () -> Void = {
        sendPasteAndReturn()
    }

    /// Extracts the canonical agent name by stripping mux prefixes and project slugs.
    public static func cleanAgentName(from raw: String) -> String {
        if raw.hasPrefix("opencode:") {
            return "opencode"
        }
        let stripped = raw.replacingOccurrences(of: "standalone:", with: "")
        let firstComponent = stripped.split(separator: ":").first.map(String.init) ?? stripped
        let noBullet = firstComponent.split(separator: "·").first.map(String.init) ?? firstComponent
        return noBullet.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the agent runs inside a desktop GUI IDE (Antigravity, Cursor, Windsurf, Zed, VS Code).
    public static func isGuiAgent(name: String) -> Bool {
        let clean = cleanAgentName(from: name)
        return clean == "antigravity" || clean == "antigravity-ide" || clean == "agy"
            || clean == "cursor" || clean == "windsurf" || clean == "cascade"
            || clean == "zed" || clean == "vscode" || clean == "code"
    }

    @MainActor
    public static func dispatchPrompt(
        agentName: String,
        text: String,
        cwd: String? = nil,
        pid: Int? = nil,
        autoSend: Bool = true
    ) {
        guard enableInputSynthesis else { return }

        let cleanName = cleanAgentName(from: agentName)

        // 1. Copy text to pasteboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // 2. Focus target application or terminal via TerminalFocusser
        _ = TerminalFocusser.focusStandalone(source: cleanName, cwd: cwd, pid: pid)

        // 3. Trackpad haptics
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic, performanceTime: .now
        )

        // 4. Synthesize input into focused agent window / prompt
        if autoSend {
            let isGui = isGuiAgent(name: cleanName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                pasteAndReturn(isGui: isGui)
            }
        }
    }

    @MainActor
    public static func dispatchApproval(
        agentName: String,
        approved: Bool,
        cwd: String? = nil,
        pid: Int? = nil
    ) {
        guard enableInputSynthesis else { return }
        let cleanName = cleanAgentName(from: agentName)
        _ = TerminalFocusser.focusStandalone(source: cleanName, cwd: cwd, pid: pid)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            KeyboardSynthesizer.approveOrDeny(approved: approved)
        }
    }

    @MainActor
    public static func dispatchOption(
        agentName: String,
        option: String,
        cwd: String? = nil,
        pid: Int? = nil
    ) {
        guard enableInputSynthesis else { return }
        dispatchPrompt(agentName: agentName, text: option, cwd: cwd, pid: pid, autoSend: true)
    }

    @MainActor
    public static func dispatchAbort(
        agentName: String,
        cwd: String? = nil,
        pid: Int? = nil
    ) {
        guard enableInputSynthesis else { return }
        let cleanName = cleanAgentName(from: agentName)
        _ = TerminalFocusser.focusStandalone(source: cleanName, cwd: cwd, pid: pid)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            KeyboardSynthesizer.interrupt()
        }
    }

    private static func sendPasteAndReturn() {
        pasteAndReturn(isGui: false)
    }

    private static func pasteAndReturn(isGui: Bool) {
        // GUI IDEs focus their chat input with Command+L. Terminal CLIs paste
        // straight into the active prompt with Command+V.
        KeyboardSynthesizer.pasteAndReturn(focusChatFirst: isGui)
    }
}
