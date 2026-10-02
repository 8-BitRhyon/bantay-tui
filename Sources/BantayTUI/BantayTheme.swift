import SwiftUI

/// Unified Design System tokens for Bantay-TUI.
/// Provides authoritative color palettes, optical spacing, concentric corner radii,
/// and sensory micro-animations across the Notch HUD, Mascot, Peek Panel, Task Widget, and Settings.
public enum BantayTheme {
    // MARK: - Surfaces & Backgrounds (Dark OLED Glass)
    public static let notchBlack = Color.black
    public static let deepBackground = Color(hex: "090A0F")
    public static let panelBackground = Color(hex: "0D0E15")
    public static let sidebarBackground = Color(hex: "08090D")
    public static let cardBackground = Color.white.opacity(0.04)
    public static let cardHover = Color.white.opacity(0.08)
    public static let cardSelected = Color.white.opacity(0.12)

    // MARK: - Borders & Dividers
    public static let borderSubtle = Color.white.opacity(0.07)
    public static let borderStandard = Color.white.opacity(0.12)
    public static let borderProminent = Color.white.opacity(0.22)
    public static let divider = Color.white.opacity(0.06)

    // MARK: - Semantic Status Palette (WCAG AAA High-Contrast)
    public static let statusWorking = Color(hex: "64D2FF")  // Cyan / In-Progress
    public static let statusCompleted = Color(hex: "30D158")  // Emerald / Success
    public static let statusAttention = Color(hex: "FFD60A")  // Amber / Needs Attention
    public static let statusFailed = Color(hex: "FF453A")  // Coral Red / Error
    public static let statusQuota = Color(hex: "FF9F0A")  // Orange / Quota Warning
    public static let statusIdle = Color(hex: "8E8E93")  // Silver / Standby

    // MARK: - Text Hierarchy
    public static let textPrimary = Color.white
    public static let textSecondary = Color.white.opacity(0.72)
    public static let textTertiary = Color.white.opacity(0.48)
    public static let textQuaternary = Color.white.opacity(0.28)

    // MARK: - Optical Corner Radii (Concentric: outer = inner + padding)
    public static let radiusTiny: CGFloat = 4
    public static let radiusSmall: CGFloat = 6
    public static let radiusMedium: CGFloat = 10
    public static let radiusCard: CGFloat = 12
    public static let radiusPanel: CGFloat = 16
    public static let radiusIsland: CGFloat = 24

    // MARK: - Spacing & Margins Scale ("Distance")
    public static let space2: CGFloat = 2
    public static let space4: CGFloat = 4
    public static let space6: CGFloat = 6
    public static let space8: CGFloat = 8
    public static let space10: CGFloat = 10
    public static let space12: CGFloat = 12
    public static let space14: CGFloat = 14
    public static let space16: CGFloat = 16
    public static let space20: CGFloat = 20

    // MARK: - Tactile Spring Presets
    public static let springSnappy = Animation.spring(response: 0.22, dampingFraction: 0.75)
    public static let springSmooth = Animation.spring(response: 0.36, dampingFraction: 0.82)
    public static let springTactile = Animation.spring(response: 0.18, dampingFraction: 0.68)

    // MARK: - Semantic Color Resolvers
    public static func color(for state: MascotState) -> Color {
        switch state {
        case .idle: return statusIdle
        case .working: return statusWorking
        case .needsAttention: return statusAttention
        case .completed: return statusCompleted
        case .quotaLow: return statusQuota
        }
    }
}
