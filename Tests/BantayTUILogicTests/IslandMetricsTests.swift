#if canImport(Testing)
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
            let w = IslandMetrics.notchWidth(
                screenWidth: 1512, auxLeft: 651, auxRight: 651, safeTop: 0)
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
            #expect(IslandMetrics.shouldExpand(hovering: true, hasAgents: false))
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
            #expect(IslandMetrics.requiresApproval("waiting"))
            #expect(!IslandMetrics.requiresApproval("progress"))
            #expect(!IslandMetrics.requiresApproval("idle"))
        }

        @Test("popup hover does not steal the approval card")
        func popupHover() {
            #expect(
                IslandMetrics.shouldExpandOnHover(
                    hovering: true, isExpanded: false, hasPopup: false))
            #expect(
                !IslandMetrics.shouldExpandOnHover(
                    hovering: true, isExpanded: false, hasPopup: true))
            #expect(
                !IslandMetrics.shouldExpandOnHover(
                    hovering: false, isExpanded: false, hasPopup: false))
            #expect(
                !IslandMetrics.shouldExpandOnHover(
                    hovering: true, isExpanded: true, hasPopup: false))
        }

        @Test("actionable pane id resolves standalone agents")
        func actionablePaneId() {
            #expect(
                IslandMetrics.actionablePaneId(paneId: "w3:p1", source: "claude") == "w3:p1")
            #expect(
                IslandMetrics.actionablePaneId(paneId: nil, source: "claude")
                    == "standalone:claude")
            #expect(
                IslandMetrics.actionablePaneId(paneId: "", source: "opencode")
                    == "standalone:opencode")
            #expect(IslandMetrics.actionablePaneId(paneId: nil, source: nil) == nil)
        }

        @Test("global rect converts to screen coordinates")
        func screenRectConversion() {
            let screenRect = IslandMetrics.screenRect(
                fromGlobalRect: CGRect(x: 24, y: 0, width: 456, height: 82),
                windowFrame: CGRect(x: 600, y: 530, width: 504, height: 560))
            #expect(screenRect.minX == 624)
            #expect(screenRect.maxY == 1090)
            #expect(screenRect.minY == 1008)
            #expect(screenRect.width == 456)
            #expect(screenRect.height == 82)
        }

        @Test("notifications clear the notch")
        func notificationPlacement() {
            #expect(
                IslandMetrics.notificationTopOffset(topInset: 38)
                    == 38 + IslandMetrics.notificationTopGap)
            #expect(
                IslandMetrics.notificationCardHeight(for: .accessRequest)
                    == IslandMetrics.approvalNotificationHeight)
            #expect(
                IslandMetrics.notificationCardHeight(for: .waiting)
                    == IslandMetrics.approvalNotificationHeight)
            #expect(
                IslandMetrics.notificationCardHeight(for: .completed)
                    == IslandMetrics.notificationHeight)
            let size = IslandMetrics.closedSize(
                topInset: 38, notchWidth: 200, hasNotification: true,
                cardHeight: IslandMetrics.approvalNotificationHeight)
            #expect(
                size.height
                    == 38 + IslandMetrics.notificationTopGap
                    + IslandMetrics.approvalNotificationHeight)
            #expect(size.width == IslandMetrics.notificationWidth)
        }

        @Test("morph style")
        func morphStyle() {
            #expect(IslandMetrics.morphStyle(reduceMotion: true) == .linear)
            #expect(IslandMetrics.morphStyle(reduceMotion: false) == .spring)
        }

        @Test("hover scale")
        func hoverScale() {
            #expect(IslandMetrics.hoverScale(isHovered: false, isExpanded: true) == 1)
            #expect(
                abs(IslandMetrics.hoverScale(isHovered: true, isExpanded: false) - 1.02) < 0.001)
            #expect(
                abs(IslandMetrics.hoverScale(isHovered: true, isExpanded: true) - 1.012) < 0.001)
        }

        @Test("fractional screen")
        func fractionalScreen() {
            let wf = IslandMetrics.windowFrame(
                screenFrame: CGRect(x: 0, y: 0, width: 1367, height: 800),
                size: IslandMetrics.windowSize(), scale: 1)
            #expect(abs(wf.midX - 1367 / 2) <= midXTol)
        }
    }

    @Suite("Approval detail text")
    struct ApprovalDetailTests {
        @Test("keeps commands and paths intact")
        func keepsActualRequest() {
            let raw = "\u{001B}[31mBash\u{001B}[0m\nrm -rf /Users/test/Projects/demo/build"
            let cleaned = IslandMetrics.cleanApprovalDetail(raw)
            #expect(cleaned.contains("/Users/test/Projects/demo/build"))
            #expect(!cleaned.contains("\u{001B}"))
            #expect(cleaned.contains("Bash"))
        }

        @Test("detects generic approval text")
        func genericText() {
            #expect(IslandMetrics.isGenericApprovalText(nil))
            #expect(IslandMetrics.isGenericApprovalText(""))
            #expect(IslandMetrics.isGenericApprovalText("Agent requires input"))
            #expect(IslandMetrics.isGenericApprovalText("Claude needs approval"))
            #expect(!IslandMetrics.isGenericApprovalText("rm -rf build"))
            #expect(!IslandMetrics.isGenericApprovalText("Allow writing /tmp/file?"))
        }

        @Test("pane excerpt drops chrome and keeps the prompt")
        func paneExcerpt() {
            let excerpt = IslandMetrics.approvalExcerpt(
                from: "line1\n──────\nDo you want to proceed?\nEsc to interrupt",
                maxLines: 4)
            #expect(excerpt.contains("Do you want to proceed?"))
            #expect(!excerpt.contains("Esc to interrupt"))
        }

        @Test("live excerpt needs a prompt signal")
        func promptGate() {
            #expect(IslandMetrics.looksLikePrompt("Do you want to proceed?"))
            #expect(IslandMetrics.looksLikePrompt("1. Staging\n2. Production"))
            #expect(IslandMetrics.looksLikePrompt("Allow writing /tmp/file? (y/n)"))
            #expect(!IslandMetrics.looksLikePrompt("Muse Spark 1.3 Contributor"))
            #expect(
                !IslandMetrics.looksLikePrompt(
                    "Jump to latest\nBuild succeeded in 2s"))
            #expect(!IslandMetrics.looksLikePrompt(""))
        }
    }

    @Suite("HUD Text Sanitization")
    struct HUDTextSanitizationTests {
        @Test("strips ANSI color escapes and control characters")
        func stripsAnsiCodes() {
            let ansi = "\u{001B}[38;5;208mRunning tests\u{001B}[0m"
            #expect(IslandMetrics.cleanHUDText(ansi) == "Running tests")

            let cursorCode = "\u{001B}[2K\u{001B}[1GCompiling sources"
            #expect(IslandMetrics.cleanHUDText(cursorCode) == "Compiling sources")
        }

        @Test("strips terminal braille spinners")
        func stripsBrailleSpinners() {
            let spinner = "⠋ Inspecting directory tree"
            #expect(IslandMetrics.cleanHUDText(spinner) == "Inspecting directory tree")
            let midSpinner = "Building ⠹ project"
            #expect(IslandMetrics.cleanHUDText(midSpinner) == "Building project")
        }

        @Test("strips log envelopes and ISO timestamps")
        func stripsLogEnvelopes() {
            let logLine = "2026-10-01T12:00:00Z [INFO] level=info Building project"
            #expect(IslandMetrics.cleanHUDText(logLine) == "Building project")
        }

        @Test("strips syslog and Apple log timestamps")
        func stripsSyslogTimestamps() {
            let syslog = "2026-10-16 09:12:48.169514-0500 bantay: Running task"
            #expect(IslandMetrics.cleanHUDText(syslog) == "Running task")

            let bareSyslog = "2026-10-16 09:12:48.169514-0500 bantay"
            #expect(IslandMetrics.isSuppressedGarbage(bareSyslog))
            #expect(IslandMetrics.cleanHUDText(bareSyslog) == "")
        }

        @Test("suppresses raw JSON blobs")
        func suppressesRawJSON() {
            let json = "{\"role\":\"assistant\",\"content\":\"Working\"}"
            #expect(IslandMetrics.isSuppressedGarbage(json))
            #expect(IslandMetrics.cleanHUDText(json) == "")
        }

        @Test("suppresses hostnames and shell prompts")
        func suppressesHostnames() {
            #expect(IslandMetrics.isSuppressedGarbage("MacBook-Pro.local"))
            #expect(IslandMetrics.cleanHUDText("MacBook-Pro.local") == "")
            #expect(IslandMetrics.isSuppressedGarbage("rhyon@mbp:~$"))
            #expect(IslandMetrics.cleanHUDText("rhyon@mbp:~$") == "")
        }

        @Test("strips progress bars and percentages")
        func stripsProgressBars() {
            let progress = "[====>    ] 45% Compiling"
            #expect(IslandMetrics.cleanHUDText(progress) == "Compiling")
        }
    }
#endif
