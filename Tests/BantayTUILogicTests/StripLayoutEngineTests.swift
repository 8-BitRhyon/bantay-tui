#if canImport(Testing)
    import Foundation
    import Testing

    @testable import BantayTUI

    @Suite("StripLayoutEngine logic", .serialized)
    struct StripLayoutEngineTests {
        @Test("computeLayout calculates column frames, total width and max scroll")
        func testComputeLayout() {
            let win1 = StripWindowInfo(id: "win1", title: "Terminal")
            let win2 = StripWindowInfo(id: "win2", title: "Claude Code")
            let win3 = StripWindowInfo(id: "win3", title: "Codex")

            let col1 = StripColumn(id: "col1", windows: [win1], widthFraction: 0.5)
            let col2 = StripColumn(id: "col2", windows: [win2], widthFraction: 0.5)
            let col3 = StripColumn(id: "col3", windows: [win3], widthFraction: 0.5)

            let viewport = StripViewport(
                screenOriginX: 0.0,
                screenOriginY: 0.0,
                screenWidth: 1000.0,
                screenHeight: 600.0,
                gap: 10.0,
                inset: 10.0,
                scrollOffset: 0.0
            )

            let layout = StripLayoutEngine.computeLayout(
                columns: [col1, col2, col3],
                viewport: viewport
            )

            #expect(layout.columnFrames.count == 3)
            #expect(layout.totalStripWidth > viewport.screenWidth)
            #expect(layout.maxScrollOffset > 0.0)
            #expect(layout.windowFrames["win1"] != nil)
            #expect(layout.windowFrames["win2"] != nil)
            #expect(layout.windowFrames["win3"] != nil)
            #expect(layout.visibleWindowIDs.contains("win1"))
            #expect(layout.visibleWindowIDs.contains("win2"))
        }

        @Test("computeLayout splits stacked column heights evenly with gaps")
        func testStackedColumnLayout() {
            let win1 = StripWindowInfo(id: "w1", title: "Top")
            let win2 = StripWindowInfo(id: "w2", title: "Bottom")
            let col = StripColumn(id: "c1", windows: [win1, win2], widthFraction: 0.5)

            let viewport = StripViewport(
                screenWidth: 1000.0,
                screenHeight: 600.0,
                gap: 10.0,
                inset: 10.0
            )
            let layout = StripLayoutEngine.computeLayout(columns: [col], viewport: viewport)

            let f1 = layout.windowFrames["w1"]
            let f2 = layout.windowFrames["w2"]
            #expect(f1 != nil && f2 != nil)
            if let f1, let f2 {
                #expect(abs(f1.height - f2.height) < 0.1)
                #expect(f2.y > f1.maxY)
            }
        }

        @Test("revealTarget computes minimal scroll required to bring column into view")
        func testRevealTarget() {
            let col1 = StripColumn(
                id: "c1",
                windows: [StripWindowInfo(id: "w1")],
                widthFraction: 0.5
            )
            let col2 = StripColumn(
                id: "c2",
                windows: [StripWindowInfo(id: "w2")],
                widthFraction: 0.5
            )
            let col3 = StripColumn(
                id: "c3",
                windows: [StripWindowInfo(id: "w3")],
                widthFraction: 0.5
            )

            let viewport = StripViewport(
                screenWidth: 1000.0,
                screenHeight: 600.0,
                gap: 10.0,
                inset: 10.0,
                scrollOffset: 0.0
            )

            let target0 = StripLayoutEngine.revealTarget(
                columnIndex: 0,
                columns: [col1, col2, col3],
                viewport: viewport
            )
            #expect(target0 == 0.0)

            let target2 = StripLayoutEngine.revealTarget(
                columnIndex: 2,
                columns: [col1, col2, col3],
                viewport: viewport
            )
            #expect(target2 > 0.0)
        }

        @Test("centerTarget calculates horizontal center scroll offset")
        func testCenterTarget() {
            let col1 = StripColumn(
                id: "c1",
                windows: [StripWindowInfo(id: "w1")],
                widthFraction: 0.5
            )
            let col2 = StripColumn(
                id: "c2",
                windows: [StripWindowInfo(id: "w2")],
                widthFraction: 0.5
            )

            let viewport = StripViewport(
                screenWidth: 1000.0,
                screenHeight: 600.0,
                gap: 10.0,
                inset: 10.0,
                scrollOffset: 0.0
            )

            let center = StripLayoutEngine.centerTarget(
                columnIndex: 1,
                columns: [col1, col2],
                viewport: viewport
            )
            #expect(center >= 0.0)
        }

        @Test("cycleWidth and toggleFullWidth cycle fractions accurately")
        func testWidthCycling() {
            let nextFromHalf = StripLayoutEngine.cycleWidth(currentFraction: 0.5)
            #expect(abs(nextFromHalf - (2.0 / 3.0)) < 0.01)

            let wrapFromFull = StripLayoutEngine.cycleWidth(currentFraction: 1.0)
            #expect(abs(wrapFromFull - 0.25) < 0.01)

            let (fullW, saved) = StripLayoutEngine.toggleFullWidth(
                currentFraction: 0.5,
                savedFraction: nil
            )
            #expect(fullW == 1.0)
            #expect(saved == 0.5)

            let (restored, saved2) = StripLayoutEngine.toggleFullWidth(
                currentFraction: 1.0,
                savedFraction: saved
            )
            #expect(restored == 0.5)
            #expect(saved2 == nil)
        }

        @Test("findApprovalColumnIndex detects columns needing human approval")
        func testApprovalDiscovery() {
            let winWorking = StripWindowInfo(
                id: "w1",
                agentName: "claude",
                agentStatus: .working
            )
            let winBlocked = StripWindowInfo(
                id: "w2",
                agentName: "codex",
                agentStatus: .needsApproval
            )

            let col1 = StripColumn(id: "c1", windows: [winWorking])
            let col2 = StripColumn(id: "c2", windows: [winBlocked])

            let approvalIdx = StripLayoutEngine.findApprovalColumnIndex(
                columns: [col1, col2]
            )
            #expect(approvalIdx == 1)

            let codexIdx = StripLayoutEngine.findAgentColumnIndex(
                agentName: "codex",
                columns: [col1, col2]
            )
            #expect(codexIdx == 1)
        }

        @Test("DampedSpring simulation converges toward target")
        func testSpringPhysics() {
            var spring = DampedSpring(initialValue: 0.0)
            spring.target = 500.0

            for _ in 0..<120 {
                _ = spring.step(dt: 0.016, omega: 13.0)
            }

            #expect(abs(spring.x - 500.0) < 1.0)

            spring.target = 1000.0
            spring.snap()
            #expect(spring.x == 1000.0)
            #expect(spring.v == 0.0)

            let rubber = DampedSpring.rubberBand(
                offset: -100.0,
                maxOffset: 500.0,
                screenWidth: 1000.0
            )
            #expect(rubber < 0.0 && rubber > -100.0)
        }

        @Test("stack, unstack, and reorder modify column topology correctly")
        func testTopologicalOperations() {
            var cols = [
                StripColumn(id: "c1", windows: [StripWindowInfo(id: "w1")]),
                StripColumn(id: "c2", windows: [StripWindowInfo(id: "w2")]),
            ]

            let stacked = StripLayoutEngine.stack(
                sourceColIndex: 0,
                targetColIndex: 1,
                columns: &cols
            )
            #expect(stacked)
            #expect(cols.count == 1)
            #expect(cols[0].windows.count == 2)

            let unstacked = StripLayoutEngine.unstack(
                columnIndex: 0,
                popToRight: true,
                columns: &cols
            )
            #expect(unstacked)
            #expect(cols.count == 2)
            #expect(cols[0].windows.count == 1)
            #expect(cols[1].windows.count == 1)

            let reordered = StripLayoutEngine.reorder(
                fromIndex: 0,
                toIndex: 1,
                columns: &cols
            )
            #expect(reordered)
            #expect(cols[0].windows[0].id == "w1")
        }
    }
#endif
