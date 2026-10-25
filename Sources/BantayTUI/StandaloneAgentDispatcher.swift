import AppKit
import ApplicationServices
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

    /// Accessibility gate: synthesized keystrokes silently fail without
    /// the grant. Callers treat false as delivery failure, never success.
    public static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    @MainActor
    @discardableResult
    public static func dispatchPrompt(
        agentName: String,
        text: String,
        cwd: String? = nil,
        pid: Int? = nil,
        autoSend: Bool = true
    ) -> Bool {
        guard enableInputSynthesis, accessibilityGranted() else { return false }

        let cleanName = cleanAgentName(from: agentName)

        // 1. Save the whole pasteboard (every item and type) so images,
        // RTF, and file URLs survive the dispatch, not just the first string.
        let clipboard = captureClipboard()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // 2. Focus target application or terminal via TerminalFocusser.
        // A failed focus aborts: pasting into the frontmost window would
        // inject the task into the wrong app.
        guard TerminalFocusser.focusStandalone(source: cleanName, cwd: cwd, pid: pid) else {
            restoreClipboard(clipboard)
            return false
        }

        // 3. Trackpad haptics
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic, performanceTime: .now
        )

        // 4. Synthesize input into focused agent window / prompt
        if autoSend {
            let isGui = isGuiAgent(name: cleanName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                pasteAndReturn(isGui: isGui)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
                    restoreClipboard(clipboard)
                }
            }
        } else {
            restoreClipboard(clipboard)
        }
        return true
    }

    /// Clipboard snapshot: every pasteboard item with every data type.
    private struct ClipboardSnapshot {
        var items: [[NSPasteboard.PasteboardType: Data]] = []
    }

    private static func captureClipboard() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        guard let items = pasteboard.pasteboardItems else { return ClipboardSnapshot() }
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        for item in items {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            if !entry.isEmpty { saved.append(entry) }
        }
        return ClipboardSnapshot(items: saved)
    }

    /// Restores every saved item and type. Best effort: a pasteboard that
    /// refuses a write is left cleared rather than half-written.
    private static func restoreClipboard(_ snapshot: ClipboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items = snapshot.items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
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
