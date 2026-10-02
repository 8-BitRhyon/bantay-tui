import AppKit
import CoreGraphics
import Foundation

public enum StandaloneAgentDispatcher {
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
                sendPasteAndReturn()
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
