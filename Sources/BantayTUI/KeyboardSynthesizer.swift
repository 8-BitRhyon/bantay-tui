import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Posts synthetic keyboard events directly through Core Graphics.
///
/// Bantay already needs Accessibility to tile windows. Reusing that grant for
/// keystrokes avoids `NSAppleScript` and System Events, which trigger a
/// separate macOS Automation prompt on every freshly signed build.
enum KeyboardSynthesizer {
    /// ANSI virtual key codes. They are layout-independent for the keys
    /// Bantay sends; `type` uses Unicode events for arbitrary characters.
    enum Key {
        static let `return`: CGKeyCode = 36
        static let escape: CGKeyCode = 53
        static let y: CGKeyCode = 16
        static let n: CGKeyCode = 45
        static let c: CGKeyCode = 8
        static let l: CGKeyCode = 37
        static let v: CGKeyCode = 9
    }

    /// Reads the existing Accessibility grant. This check never prompts.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Post one key down/up pair with optional modifiers. Returns false when
    /// Accessibility is missing (macOS would silently drop the event anyway).
    @discardableResult
    static func press(_ key: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        guard isTrusted else {
            NSLog("bantay-input: Accessibility not granted; key event dropped")
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(
                keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(
                keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Type a single character as a Unicode keyboard event. This is used for
    /// approval letters so a non-US layout cannot turn "y" into another key.
    @discardableResult
    static func type(_ character: Character) -> Bool {
        guard isTrusted else {
            NSLog("bantay-input: Accessibility not granted; text event dropped")
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        var utf16 = Array(String(character).utf16)
        guard !utf16.isEmpty else { return false }
        guard
            let down = CGEvent(
                keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(
                keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }
        down.keyboardSetUnicodeString(
            stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(
            stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Focus a chat box (optional), paste the clipboard, then submit.
    static func pasteAndReturn(focusChatFirst: Bool) {
        if focusChatFirst {
            press(Key.l, flags: .maskCommand)
            Thread.sleep(forTimeInterval: 0.12)
        }
        press(Key.v, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.08)
        press(Key.return)
    }

    /// Answer a terminal approval prompt: the letter followed by Return.
    static func approveOrDeny(approved: Bool) {
        type(approved ? "y" : "n")
        Thread.sleep(forTimeInterval: 0.05)
        press(Key.return)
    }

    /// Send Control+C to the frontmost application.
    static func interrupt() {
        press(Key.c, flags: .maskControl)
    }
}
