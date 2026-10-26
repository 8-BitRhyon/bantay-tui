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
    public var dimInactive: Bool
    public var showNavigationChevrons: Bool
    /// Show the strip indicator while navigating (hold Control-Option to pin).
    public var showStripIndicator: Bool
    /// Keep each window's opening height instead of stretching to full height.
    public var keepOriginalHeight: Bool
    /// Leave fixed-size windows (Calculator, palettes) where they are.
    public var floatFixedSizeWindows: Bool
    /// Stop tiling a window that refuses resizes instead of fighting it.
    public var floatStubbornWindows: Bool
    /// Displays the strip leaves alone entirely.
    public var disabledDisplayKeys: [String]
    public var ignoredBundleIDs: [String]

    /// How long the navigation indicator stays before fading out.
    public static let indicatorAutoHideSeconds: TimeInterval = 1.6

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
        isEnabled: Bool = true,
        gap: Double = 12.0,
        inset: Double = 12.0,
        autoCenterOnApproval: Bool = true,
        statusHalosEnabled: Bool = true,
        hotkeysEnabled: Bool = true,
        defaultWidthPreset: Double = 0.5,
        springOmega: Double = 13.0,
        dimInactive: Bool = true,
        showNavigationChevrons: Bool = true,
        showStripIndicator: Bool = true,
        keepOriginalHeight: Bool = false,
        floatFixedSizeWindows: Bool = true,
        floatStubbornWindows: Bool = true,
        disabledDisplayKeys: [String] = [],
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
        self.dimInactive = dimInactive
        self.showNavigationChevrons = showNavigationChevrons
        self.showStripIndicator = showStripIndicator
        self.keepOriginalHeight = keepOriginalHeight
        self.floatFixedSizeWindows = floatFixedSizeWindows
        self.floatStubbornWindows = floatStubbornWindows
        self.disabledDisplayKeys = disabledDisplayKeys
        self.ignoredBundleIDs = ignoredBundleIDs
    }

    /// Loads configuration from UserDefaults or defaults.
    public static func load(from defaults: UserDefaults = .standard) -> StripConfiguration {
        let isEnabled = defaults.object(forKey: "bantay.strip.enabled") as? Bool ?? true
        let gap = defaults.object(forKey: "bantay.strip.gap") as? Double ?? 12.0
        let inset = defaults.object(forKey: "bantay.strip.inset") as? Double ?? 12.0
        let autoCenter = defaults.object(forKey: "bantay.strip.autoCenter") as? Bool ?? true
        let halos = defaults.object(forKey: "bantay.strip.halos") as? Bool ?? true
        let hotkeys = defaults.object(forKey: "bantay.strip.hotkeys") as? Bool ?? true
        let widthPreset = defaults.object(forKey: "bantay.strip.widthPreset") as? Double ?? 0.5
        let omega = defaults.object(forKey: "bantay.strip.springOmega") as? Double ?? 13.0
        let dimInactive = defaults.object(forKey: "bantay.strip.dimInactive") as? Bool ?? true
        let chevrons = defaults.object(forKey: "bantay.strip.chevrons") as? Bool ?? true
        let indicator = defaults.object(forKey: "bantay.strip.indicator") as? Bool ?? true
        let keepHeight = defaults.object(forKey: "bantay.strip.keepHeight") as? Bool ?? false
        let floatFixed = defaults.object(forKey: "bantay.strip.floatFixed") as? Bool ?? true
        let floatStubborn = defaults.object(forKey: "bantay.strip.floatStubborn") as? Bool ?? true
        let disabledDisplays = defaults.stringArray(forKey: "bantay.strip.disabledDisplays") ?? []
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
            dimInactive: dimInactive,
            showNavigationChevrons: chevrons,
            showStripIndicator: indicator,
            keepOriginalHeight: keepHeight,
            floatFixedSizeWindows: floatFixed,
            floatStubbornWindows: floatStubborn,
            disabledDisplayKeys: disabledDisplays,
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
        defaults.set(dimInactive, forKey: "bantay.strip.dimInactive")
        defaults.set(showNavigationChevrons, forKey: "bantay.strip.chevrons")
        defaults.set(showStripIndicator, forKey: "bantay.strip.indicator")
        defaults.set(keepOriginalHeight, forKey: "bantay.strip.keepHeight")
        defaults.set(floatFixedSizeWindows, forKey: "bantay.strip.floatFixed")
        defaults.set(floatStubbornWindows, forKey: "bantay.strip.floatStubborn")
        defaults.set(disabledDisplayKeys, forKey: "bantay.strip.disabledDisplays")
        defaults.set(ignoredBundleIDs, forKey: "bantay.strip.ignored")
    }

    /// Checks if a bundle ID is ignored from tiling on the strip.
    public func isIgnored(bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return ignoredBundleIDs.contains { $0.lowercased() == lower }
    }
}
