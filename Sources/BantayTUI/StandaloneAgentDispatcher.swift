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
        return firstComponent.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    public static func dispatchPrompt(
        agentName: String,
        text: String,
        cwd: String? = nil,
        autoSend: Bool = true
    ) {
        guard enableInputSynthesis else { return }

        let cleanName = cleanAgentName(from: agentName)

        // 1. Copy text to pasteboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // 2. Focus target application or terminal via TerminalFocusser
        _ = TerminalFocusser.focusStandalone(source: cleanName, cwd: cwd)

        // 3. Trackpad haptics
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic, performanceTime: .now
        )

        // 4. Synthesize ⌘V and Return into the focused agent window
        if autoSend {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                pasteAndReturnAction()
            }
        }
    }

    private static func sendPasteAndReturn() {
        // 1. Synthesize via CGEvent directly to system event tap
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9
        let returnKeyCode: CGKeyCode = 36

        if let vDown = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true) {
            vDown.flags = .maskCommand
            vDown.post(tap: .cghidEventTap)
        }
        if let vUp = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false) {
            vUp.flags = .maskCommand
            vUp.post(tap: .cghidEventTap)
        }

        usleep(60_000)  // 60ms pause between paste and enter

        if let retDown = CGEvent(
            keyboardEventSource: src, virtualKey: returnKeyCode, keyDown: true)
        {
            retDown.post(tap: .cghidEventTap)
        }
        if let retUp = CGEvent(
            keyboardEventSource: src, virtualKey: returnKeyCode, keyDown: false)
        {
            retUp.post(tap: .cghidEventTap)
        }

        // 2. Backup via System Events AppleScript
        let script = """
            tell application "System Events"
                keystroke "v" using command down
                delay 0.06
                key code 36
            end tell
            """
        if let asObj = NSAppleScript(source: script) {
            var err: NSDictionary?
            asObj.executeAndReturnError(&err)
        }
    }
}
