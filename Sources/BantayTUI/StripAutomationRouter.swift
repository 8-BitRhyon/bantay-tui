import Foundation

/// Parses the `bantay://` automation URLs that Raycast, Shortcuts, and
/// scripts can call without the socket.
public enum AutomationCommand: Equatable, Sendable {
    case stripToggle
    case stripFocus(direction: String)
    case stripSendDisplay
    case stripOverview
    case stripPin
    case hudToggle
    case inbox
    case settings
}

public enum AutomationURL {
    public static let scheme = "bantay"

    /// Accepts bantay://strip/focus?direction=left and the equivalent
    /// bantay://focus?direction=left shorthand. Unknown paths yield nil.
    public static func parse(_ url: URL) -> AutomationCommand? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        var parts = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
        var host = (url.host ?? "").lowercased()
        if host.isEmpty { host = parts.first ?? "" }
        if let first = parts.first, first == host { parts.removeFirst() }
        let query =
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value }
            ?? [:]

        switch host {
        case "strip":
            let action = parts.first ?? "toggle"
            switch action {
            case "toggle": return .stripToggle
            case "focus":
                return .stripFocus(direction: query["direction"] ?? "right")
            case "send", "senddisplay": return .stripSendDisplay
            case "overview": return .stripOverview
            case "pin": return .stripPin
            default: return nil
            }
        case "focus":
            return .stripFocus(direction: query["direction"] ?? "right")
        case "send", "senddisplay":
            return .stripSendDisplay
        case "overview": return .stripOverview
        case "hud": return .hudToggle
        case "inbox": return .inbox
        case "settings": return .settings
        default: return nil
        }
    }
}
