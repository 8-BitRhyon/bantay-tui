import Foundation

@MainActor
final class NotchHUDConfig {
    static let shared = NotchHUDConfig()

    var stickyApprovalSources: Set<String> = ["codex", "cursor", "freebuff", "commandcode"]
    var enableAgentAlerts = true
    var soundVolume: Float = 0.35
    var autoClearTTL: TimeInterval = 3.0
    var stickyApprovalTTL: TimeInterval = 30.0

    private init() {}
}
