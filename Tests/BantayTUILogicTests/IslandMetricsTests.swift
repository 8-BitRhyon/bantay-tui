import CoreGraphics
import Testing

@testable import BantayTUI

@Suite("IslandMetrics geometry")
struct IslandMetricsGeometryTests {
    let screenW: CGFloat = 1512
    let screenH: CGFloat = 982
    let scale2: CGFloat = 2
    let safeTop: CGFloat = 47
    let auxL: CGFloat = 650.5
    let auxR: CGFloat = 650.5
    let midXTol: CGFloat = 0.5

    @Test("constants")
    func constants() {
        #expect(IslandMetrics.expandedWidth == 456)
        #expect(IslandMetrics.maxExpandedHeight == 560)
        #expect(IslandMetrics.hoverCooldown == 0.22)
        #expect(IslandMetrics.notchlessFallbackWidth == 211)
        #expect(IslandMetrics.cornerRadius(expanded: true) == 24)
        #expect(IslandMetrics.cornerRadius(expanded: false) == 8)
    }

    @Test("fixed window size is invariant")
    func fixedWindowSize() {
        #expect(IslandMetrics.windowSize() == CGSize(width: 504, height: 560))
    }

    @Test("window centered and aligned to pixel grid")
    func windowFrame() {
        let ws = IslandMetrics.windowSize()
        let wf = IslandMetrics.windowFrame(
            screenFrame: CGRect(x: 0, y: 0, width: screenW, height: screenH),
            size: ws, scale: scale2)
        #expect(abs(wf.midX - screenW / 2) <= midXTol)
        #expect(wf.maxY - screenH < 0.01)
        for s: CGFloat in [1, 2, 1.5] {
            let f = IslandMetrics.windowFrame(
                screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                size: ws, scale: s)
            let px = max(s, 1)
            #expect((f.minY * px).rounded() == (f.minY * px))
            #expect((f.minX * px).rounded() == (f.minX * px))
        }
    }

    @Test("notchless fallback")
    func notchlessFallback() {
        let w = IslandMetrics.notchWidth(screenWidth: 1512, auxLeft: 651, auxRight: 651, safeTop: 0)
        #expect(w == IslandMetrics.notchlessFallbackWidth)
    }

    @Test("oversized notch clamped")
    func oversizedClamp() {
        let sz = IslandMetrics.closedSize(topInset: 47, notchWidth: 999)
        #expect(sz.width == IslandMetrics.expandedWidth)
    }

    @Test("height cap")
    func heightCap() {
        let sz = IslandMetrics.expandedSize(topInset: 47, agentCount: 50)
        #expect(sz.height == IslandMetrics.maxExpandedHeight)
    }

    @Test("top inset fallback")
    func topInset() {
        #expect(IslandMetrics.topInset(safeTop: 47, menuBarHeight: 22) == 47)
        #expect(IslandMetrics.topInset(safeTop: 0, menuBarHeight: 22) == 22)
        #expect(IslandMetrics.topInset(safeTop: 0, menuBarHeight: 0) == 0)
    }

    @Test("hover state machine")
    func hoverStates() {
        #expect(!IslandMetrics.shouldExpand(hovering: true, hasAgents: false))
        #expect(!IslandMetrics.shouldExpand(hovering: false, hasAgents: true))
        #expect(IslandMetrics.shouldExpand(hovering: true, hasAgents: true))
        #expect(IslandMetrics.shouldCollapse(isExpanded: true, hasAgents: false))
        #expect(!IslandMetrics.shouldCollapse(isExpanded: false, hasAgents: false))
    }

    @Test("hover-out collapse and approval")
    func hoverOutCollapseAndApproval() {
        #expect(!IslandMetrics.shouldCollapseOnHoverExit(isExpanded: false, isComposing: false))
        #expect(IslandMetrics.shouldCollapseOnHoverExit(isExpanded: true, isComposing: false))
        #expect(!IslandMetrics.shouldCollapseOnHoverExit(isExpanded: true, isComposing: true))
        #expect(IslandMetrics.requiresApproval("accessRequest"))
        #expect(IslandMetrics.requiresApproval("access_request"))
        #expect(!IslandMetrics.requiresApproval("progress"))
        #expect(!IslandMetrics.requiresApproval("idle"))
    }

    @Test("morph style")
    func morphStyle() {
        #expect(IslandMetrics.morphStyle(reduceMotion: true) == .linear)
        #expect(IslandMetrics.morphStyle(reduceMotion: false) == .spring)
    }

    @Test("hover scale")
    func hoverScale() {
        #expect(IslandMetrics.hoverScale(isHovered: false, isExpanded: true) == 1)
        #expect(abs(IslandMetrics.hoverScale(isHovered: true, isExpanded: false) - 1.02) < 0.001)
        #expect(abs(IslandMetrics.hoverScale(isHovered: true, isExpanded: true) - 1.012) < 0.001)
    }

    @Test("fractional screen")
    func fractionalScreen() {
        let wf = IslandMetrics.windowFrame(
            screenFrame: CGRect(x: 0, y: 0, width: 1367, height: 800),
            size: IslandMetrics.windowSize(), scale: 1)
        #expect(abs(wf.midX - 1367 / 2) <= midXTol)
    }
}
