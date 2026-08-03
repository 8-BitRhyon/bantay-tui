import Foundation
import Testing

@testable import BantayTUI

@MainActor
@Suite("NotchHUDConfig lifecycle controls")
struct NotchHUDConfigTests {
    @Test("defaults, persistence, and snooze boundaries")
    func lifecycleControls() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "islandEnabled")
        defaults.removeObject(forKey: "snoozedUntil")

        let cfg = NotchHUDConfig.shared
        #expect(cfg.islandEnabled == true)
        #expect(cfg.isSnoozed == false)

        cfg.islandEnabled = false
        cfg.snoozedUntil = Date().addingTimeInterval(600)
        #expect(defaults.object(forKey: "islandEnabled") as? Bool == false)
        #expect(cfg.isSnoozed == true)

        cfg.snoozedUntil = Date().addingTimeInterval(-60)
        #expect(cfg.isSnoozed == false)

        cfg.islandEnabled = true
        cfg.snoozedUntil = nil
        defaults.removeObject(forKey: "islandEnabled")
        defaults.removeObject(forKey: "snoozedUntil")
    }
}
