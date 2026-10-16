import SwiftUI

extension FLXTheme {
    /// Bantay's signature Translucent Dark OLED Glass design system preset.
    public static var bantay: FLXTheme {
        bantay(accent: BantayTheme.statusWorking)
    }

    /// Dynamic Bantay preset with configurable adaptive accent.
    public static func bantay(accent: Color = BantayTheme.statusWorking) -> FLXTheme {
        FLXTheme(
            colors: FLXColorTokens(
                background: BantayTheme.deepBackground,
                foreground: BantayTheme.textPrimary,
                card: BantayTheme.cardBackground,
                cardForeground: BantayTheme.textPrimary,
                popover: BantayTheme.panelBackground,
                popoverForeground: BantayTheme.textPrimary,
                primary: accent,
                primaryForeground: Color.black,
                secondary: Color.white.opacity(0.08),
                secondaryForeground: BantayTheme.textPrimary,
                muted: Color.white.opacity(0.04),
                mutedForeground: BantayTheme.textTertiary,
                accent: accent.opacity(0.15),
                accentForeground: accent,
                destructive: BantayTheme.statusFailed,
                destructiveForeground: Color.white,
                border: BantayTheme.borderSubtle,
                input: BantayTheme.borderStandard,
                ring: accent
            ),
            radius: FLXRadiusScale(base: BantayTheme.radiusCard)
        )
    }
}
