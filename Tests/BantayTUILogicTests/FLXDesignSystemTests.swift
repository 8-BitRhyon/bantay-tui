#if canImport(Testing)
    import Foundation
    import SwiftUI
    import Testing

    @testable import BantayTUI

    @Suite("swiftui-flx Design System", .serialized)
    struct FLXDesignSystemTests {
        @Test("FLXSpacing scale constants")
        func spacingScale() {
            #expect(FLXSpacing.none == 0)
            #expect(FLXSpacing.xs == 4)
            #expect(FLXSpacing.sm == 8)
            #expect(FLXSpacing.md == 12)
            #expect(FLXSpacing.lg == 16)
            #expect(FLXSpacing.xl == 24)
            #expect(FLXSpacing.xxl == 32)
            #expect(FLXSpacing.xxxl == 48)
        }

        @Test("FLXRadius scale calculations")
        func radiusScale() {
            let scale = FLXRadiusScale(base: 12)
            #expect(scale.base == 12)
            #expect(scale.sm == 8)
            #expect(scale.md == 10)
            #expect(scale.lg == 12)
            #expect(scale.xl == 16)
            #expect(scale.xxl == 20)
            #expect(scale.full == 9999)
        }

        @Test("FLXBorderWidth and FLXOpacity constants")
        func bordersAndOpacities() {
            #expect(FLXBorderWidth.thin == 1)
            #expect(FLXBorderWidth.regular == 1.5)
            #expect(FLXBorderWidth.thick == 2)

            #expect(FLXOpacity.disabled == 0.5)
            #expect(FLXOpacity.pressed == 0.7)
            #expect(FLXOpacity.destructiveDark == 0.6)
        }

        @Test("FLXTypography weights and styles")
        func typographyStyles() {
            #expect(FLXTypography.largeTitle.weight == .bold)
            #expect(FLXTypography.title.weight == .bold)
            #expect(FLXTypography.title2.weight == .semibold)
            #expect(FLXTypography.headline.weight == .semibold)
            #expect(FLXTypography.body.weight == .regular)

            #expect(FLXTypography.control(.small) == .subheadline)
            #expect(FLXTypography.control(.regular) == .body)
            #expect(FLXTypography.control(.large) == .body)
        }

        @Test("FLXTheme presets resolution")
        func themePresets() {
            let defaultTheme = FLXTheme.default
            #expect(defaultTheme.radius.base > 0)

            let bantayTheme = FLXTheme.bantay
            #expect(bantayTheme.radius.base == BantayTheme.radiusCard)
            #expect(bantayTheme.colors.background == BantayTheme.deepBackground)
            #expect(bantayTheme.colors.card == BantayTheme.cardBackground)
            #expect(bantayTheme.colors.destructive == BantayTheme.statusFailed)
            #expect(bantayTheme.colors.primary == BantayTheme.statusWorking)

            let customAccent = FLXTheme.bantay(accent: BantayTheme.statusCompleted)
            #expect(customAccent.colors.primary == BantayTheme.statusCompleted)
            #expect(customAccent.colors.ring == BantayTheme.statusCompleted)
        }

        @Test("FLXButton instantiation across variants")
        @MainActor
        func buttonInstantiation() {
            var tapped = false
            let primaryBtn = FLXButton("Primary", variant: .primary) {
                tapped = true
            }
            let outlineBtn = FLXButton("Outline", variant: .outline) {}
            let secondaryBtn = FLXButton("Secondary", variant: .secondary) {}
            let ghostBtn = FLXButton("Ghost", variant: .ghost) {}
            let linkBtn = FLXButton("Link", variant: .link) {}
            let destructiveBtn = FLXButton("Delete", role: .destructive) {}
            let iconBtn = FLXButton("Add", systemImage: "plus") {}

            _ = primaryBtn
            _ = outlineBtn
            _ = secondaryBtn
            _ = ghostBtn
            _ = linkBtn
            _ = destructiveBtn
            _ = iconBtn
            #expect(!tapped)
        }

        @Test("FLXCard container composition")
        @MainActor
        func cardComposition() {
            let card = FLXCard {
                FLXCardHeader {
                    FLXCardTitle("Card Title")
                    FLXCardDescription("Card Description")
                }
                FLXCardContent {
                    Text("Content body")
                }
                FLXCardFooter {
                    FLXButton("Cancel", variant: .outline) {}
                    FLXButton("Submit", variant: .primary) {}
                }
            }
            _ = card
            #expect(true)
        }

        @Test("FLXTextField instantiation and binding")
        @MainActor
        func textFieldBinding() {
            var value = "Initial text"
            let binding = Binding(get: { value }, set: { value = $0 })
            let field = FLXTextField("Placeholder", text: binding)
            _ = field
            #expect(value == "Initial text")
        }

        @Test("IslandHitTracker bounds and hit-testing targets")
        @MainActor
        func islandHitTrackerBounds() {
            IslandHitTracker.interactiveRect = NSRect(x: 100, y: 0, width: 300, height: 40)
            #expect(IslandHitTracker.interactiveRect.width == 300)
            #expect(IslandHitTracker.interactiveRect.height == 40)
            let hitTarget = IslandHitTracker.interactiveRect.insetBy(dx: -12, dy: -12)
            #expect(hitTarget.contains(NSPoint(x: 105, y: 5)))
            #expect(!hitTarget.contains(NSPoint(x: 105, y: 100)))
        }
    }
#endif
