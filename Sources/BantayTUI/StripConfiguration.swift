import Foundation

/// User preferences and tuning parameters for the Bantay Strip scrolling window manager.
public struct StripConfiguration: Equatable, Sendable {
    public var isEnabled: Bool
    public var gap: Double
    public var inset: Double
    public var autoCenterOnApproval: Bool
    public var statusHalosEnabled: Bool
    public var hotkeysEnabled: Bool
    public var defaultWidthPreset: Double
    public var springOmega: Double
    public var ignoredBundleIDs: [String]

    public static let defaultIgnoredBundleIDs: [String] = [
        "com.apple.calculator",
        "com.apple.systempreferences",
        "com.apple.SystemSettings",
        "com.apple.Preview",
        "com.apple.quicklook",
        "com.apple.QuickLookUIService",
        "com.apple.finder",
        "com.apple.ArchiveUtility",
        "com.bantay-tui",
    ]

    public init(
        isEnabled: Bool = false,
        gap: Double = 12.0,
        inset: Double = 12.0,
        autoCenterOnApproval: Bool = true,
        statusHalosEnabled: Bool = true,
        hotkeysEnabled: Bool = true,
        defaultWidthPreset: Double = 0.5,
        springOmega: Double = 13.0,
        ignoredBundleIDs: [String] = defaultIgnoredBundleIDs
    ) {
        self.isEnabled = isEnabled
        self.gap = gap
        self.inset = inset
        self.autoCenterOnApproval = autoCenterOnApproval
        self.statusHalosEnabled = statusHalosEnabled
        self.hotkeysEnabled = hotkeysEnabled
        self.defaultWidthPreset = defaultWidthPreset
        self.springOmega = springOmega
        self.ignoredBundleIDs = ignoredBundleIDs
    }

    /// Loads configuration from UserDefaults or defaults.
    public static func load(from defaults: UserDefaults = .standard) -> StripConfiguration {
        let isEnabled = defaults.bool(forKey: "bantay.strip.enabled")
        let gap = defaults.object(forKey: "bantay.strip.gap") as? Double ?? 12.0
        let inset = defaults.object(forKey: "bantay.strip.inset") as? Double ?? 12.0
        let autoCenter = defaults.object(forKey: "bantay.strip.autoCenter") as? Bool ?? true
        let halos = defaults.object(forKey: "bantay.strip.halos") as? Bool ?? true
        let hotkeys = defaults.object(forKey: "bantay.strip.hotkeys") as? Bool ?? true
        let widthPreset = defaults.object(forKey: "bantay.strip.widthPreset") as? Double ?? 0.5
        let omega = defaults.object(forKey: "bantay.strip.springOmega") as? Double ?? 13.0
        let ignored =
            defaults.stringArray(forKey: "bantay.strip.ignored") ?? defaultIgnoredBundleIDs

        return StripConfiguration(
            isEnabled: isEnabled,
            gap: gap,
            inset: inset,
            autoCenterOnApproval: autoCenter,
            statusHalosEnabled: halos,
            hotkeysEnabled: hotkeys,
            defaultWidthPreset: widthPreset,
            springOmega: omega,
            ignoredBundleIDs: ignored
        )
    }

    /// Persists configuration to UserDefaults.
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: "bantay.strip.enabled")
        defaults.set(gap, forKey: "bantay.strip.gap")
        defaults.set(inset, forKey: "bantay.strip.inset")
        defaults.set(autoCenterOnApproval, forKey: "bantay.strip.autoCenter")
        defaults.set(statusHalosEnabled, forKey: "bantay.strip.halos")
        defaults.set(hotkeysEnabled, forKey: "bantay.strip.hotkeys")
        defaults.set(defaultWidthPreset, forKey: "bantay.strip.widthPreset")
        defaults.set(springOmega, forKey: "bantay.strip.springOmega")
        defaults.set(ignoredBundleIDs, forKey: "bantay.strip.ignored")
    }

    /// Checks if a bundle ID is ignored from tiling on the strip.
    public func isIgnored(bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return ignoredBundleIDs.contains { $0.lowercased() == lower }
    }
}
