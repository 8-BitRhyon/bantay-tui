import AppKit
import Foundation

@main
struct LogicCheckMain {
    static func main() {

        var failures = 0

        func check(_ condition: Bool, _ name: String) {
            if condition {
                print("PASS \(name)")
            } else {
                failures += 1
                print("FAIL \(name)")
            }
        }

        func agent(_ name: String, _ status: String, pane: String) -> HerdrAgentInfo {
            HerdrAgentInfo(
                agent: name,
                agentStatus: status,
                paneId: pane,
                workspaceId: String(pane.split(separator: ":").first ?? ""),
                terminalTitle: "\(name) | \(status)")
        }

        func expectKinds(_ events: [AgentEvent], _ kinds: [AgentEventKind], _ name: String) {
            check(events.map(\.kind) == kinds, "\(name): \(events.map(\.kind)) != \(kinds)")
        }

        // MARK: - capture update() logic

        var seen: [String: AgentEventKind] = [:]
        let first = AgentEventManager.update(
            from: [agent("kilo", "working", pane: "w3:p3")],
            lastSeenKinds: &seen,
            current: nil)
        expectKinds(first.events, [.progress], "first poll emits working")
        check(first.events.first?.playSound == true, "first poll plays sound")
        check(first.events.first?.persistent == true, "working is persistent")
        check(first.roster.map(\.source) == ["kilo"], "roster has kilo")

        var seen2: [String: AgentEventKind] = [:]
        let firstCall = AgentEventManager.update(
            from: [agent("kilo", "working", pane: "w3:p3")],
            lastSeenKinds: &seen2,
            current: nil)
        let same = AgentEventManager.update(
            from: [agent("kilo", "working", pane: "w3:p3")],
            lastSeenKinds: &seen2,
            current: firstCall.events.first)
        check(same.events.isEmpty, "same state does not re-emit")

        var seen3: [String: AgentEventKind] = [:]
        _ = AgentEventManager.update(
            from: [agent("kilo", "working", pane: "w3:p3")],
            lastSeenKinds: &seen3,
            current: nil)
        let blocked = AgentEventManager.update(
            from: [agent("kilo", "blocked", pane: "w3:p3")],
            lastSeenKinds: &seen3,
            current: nil)
        expectKinds(blocked.events, [.accessRequest], "working -> blocked emits accessRequest")

        var seen4: [String: AgentEventKind] = [:]
        let idle = AgentEventManager.update(
            from: [agent("kilo", "idle", pane: "w3:p3")],
            lastSeenKinds: &seen4,
            current: nil)
        check(idle.events.isEmpty, "idle emits no event")
        check(idle.roster.map(\.kind) == [.idle], "idle is in roster")

        var seen5: [String: AgentEventKind] = [:]
        let unknown = AgentEventManager.update(
            from: [agent("kilo", "unknown", pane: "w3:p3")],
            lastSeenKinds: &seen5,
            current: nil)
        check(unknown.events.isEmpty && unknown.roster.isEmpty, "unknown excluded")

        var seen6: [String: AgentEventKind] = [:]
        let done = AgentEventManager.update(
            from: [agent("kilo", "done", pane: "w3:p3")],
            lastSeenKinds: &seen6,
            current: nil)
        check(done.events.first?.kind == .completed, "done maps to completed")
        check(done.events.first?.persistent == false, "done is not persistent")

        var seen7: [String: AgentEventKind] = [:]
        let sorted = AgentEventManager.update(
            from: [
                agent("kilo", "working", pane: "w3:p3"),
                agent("freebuff", "blocked", pane: "w3:p4"),
                agent("kilo2", "done", pane: "w3:p5"),
            ],
            lastSeenKinds: &seen7,
            current: nil)
        check(
            sorted.roster.map(\.kind) == [.accessRequest, .completed, .progress],
            "roster sorted by severity")

        var seen8: [String: AgentEventKind] = [:]
        let shown = AgentEvent(
            source: "kilo",
            kind: .progress,
            title: nil,
            message: nil,
            paneId: "w3:p3",
            workspaceId: "w3",
            variance: nil,
            choices: nil,
            playSound: true,
            persistent: true)
        let empty = AgentEventManager.update(from: [], lastSeenKinds: &seen8, current: shown)
        expectKinds(empty.events, [.clear], "empty agents clears persistent event")
        check(empty.roster.isEmpty, "empty agents clears roster")

        var seen9: [String: AgentEventKind] = [:]
        let pair = AgentEventManager.update(
            from: [
                agent("kilo", "blocked", pane: "w3:p3"),
                agent("freebuff", "working", pane: "w3:p4"),
            ],
            lastSeenKinds: &seen9,
            current: nil)
        expectKinds(pair.events, [.progress, .accessRequest], "two agents emit both")
        let fallback = AgentEventManager.update(
            from: [agent("freebuff", "working", pane: "w3:p4")],
            lastSeenKinds: &seen9,
            current: pair.events.last!)
        expectKinds(
            fallback.events, [.clear, .progress], "vanish clears shown, falls back silently")
        check(
            fallback.events.last?.source == "freebuff" && fallback.events.last?.playSound == false,
            "fallback is silent freebuff")

        var seen10: [String: AgentEventKind] = [:]
        _ = AgentEventManager.update(
            from: [agent("kilo", "working", pane: "w3:p3")],
            lastSeenKinds: &seen10,
            current: nil)
        let reshown = AgentEventManager.update(
            from: [agent("kilo", "working", pane: "w3:p3")],
            lastSeenKinds: &seen10,
            current: nil)
        expectKinds(reshown.events, [.progress], "same state reshows when current nil")
        check(reshown.events.first?.playSound == false, "reshow is silent")

        // MARK: - showEvent persistence (the blink bug)

        let tmp = NSTemporaryDirectory() + "bantay-check-events.jsonl"
        try? FileManager.default.removeItem(atPath: tmp)
        FileManager.default.createFile(atPath: tmp, contents: nil)

        let manager = AgentEventManager(eventsFileURL: URL(fileURLWithPath: tmp), capture: false)
        func appendLine(_ json: String) {
            let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: tmp))
            try! handle.seekToEnd()
            try! handle.write(contentsOf: Data((json + "\n").utf8))
            try! handle.close()
        }
        func fileEvent(_ type: String) -> String {
            "{\"source\":\"herdr\",\"type\":\"\(type)\",\"title\":\"working\",\"message\":null,\"paneId\":\"w3:p3\",\"workspaceId\":\"w3\"}"
        }

        appendLine(fileEvent("progress"))
        manager.poll()
        check(manager.currentEvent?.kind == .progress, "file event shows")
        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        check(manager.currentEvent == nil, "transient file event auto-clears after TTL")

        appendLine(fileEvent("progress"))
        manager.poll()
        check(manager.currentEvent?.kind == .progress, "second file event shows")
        manager.stop()

        manager.start()
        appendLine(fileEvent("clear"))
        manager.poll()
        check(manager.currentEvent == nil, "clear dismisses")

        let eventA = AgentEvent(
            source: "kilo", kind: .progress, title: "t", message: nil, paneId: nil,
            workspaceId: nil, variance: nil, choices: nil, playSound: true, persistent: true)
        let eventB = AgentEvent(
            source: "kilo", kind: .progress, title: "t2", message: nil, paneId: nil,
            workspaceId: nil, variance: nil, choices: nil, playSound: true, persistent: true)
        check(manager.shouldPlaySound(for: eventA), "first sound plays")
        check(!manager.shouldPlaySound(for: eventB), "second sound within cooldown suppressed")
        let eventC = AgentEvent(
            source: "freebuff", kind: .progress, title: "t", message: nil, paneId: nil,
            workspaceId: nil, variance: nil, choices: nil, playSound: true, persistent: true)
        check(manager.shouldPlaySound(for: eventC), "different source not suppressed")

        var seenWorst: [String: AgentEventKind] = [:]
        let simultaneous = AgentEventManager.update(
            from: [
                agent("kilo", "blocked", pane: "w3:p3"),
                agent("freebuff", "done", pane: "w3:p4"),
            ],
            lastSeenKinds: &seenWorst,
            current: nil)
        expectKinds(
            simultaneous.events, [.completed, .accessRequest],
            "worst state sorted last wins the pill")

        manager.stop()
        try? FileManager.default.removeItem(atPath: tmp)

        // MARK: - IslandMetrics geometry

        func assertCGSizeEqual(_ a: CGSize, _ b: CGSize, _ name: String) {
            check(
                abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001,
                "\(name): \(a) != \(b)")
        }

        func assertCGRectContainsCenter(_ f: CGRect, cx: CGFloat, _ name: String) {
            check(abs(f.midX - cx) < 0.01, "\(name) midX \(f.midX) != \(cx)")
        }

        // -- Constants

        check(IslandMetrics.expandedWidth == 456, "expandedWidth 456")
        check(IslandMetrics.maxExpandedHeight == 560, "maxExpandedHeight 560")
        check(IslandMetrics.hoverCooldown == 0.22, "hoverCooldown 0.22")
        check(IslandMetrics.notchlessFallbackWidth == 211, "notchlessFallbackWidth 211")
        check(IslandMetrics.cornerRadius(expanded: true) == 24, "expanded cornerRadius 24")
        check(IslandMetrics.cornerRadius(expanded: false) == 8, "closed cornerRadius 8")

        // -- Fixed window size (invariant 1)

        let ws = IslandMetrics.windowSize()
        assertCGSizeEqual(ws, CGSize(width: 504, height: 560), "fixed window size")

        // -- Symmetry: pill centers equal window center (invariant 3)

        let screenW: CGFloat = 1512
        let screenH: CGFloat = 982
        let scale2: CGFloat = 2
        let safeTop: CGFloat = 47
        let auxL: CGFloat = 650.5
        let auxR: CGFloat = 650.5
        let notchW = IslandMetrics.notchWidth(
            screenWidth: screenW, auxLeft: auxL, auxRight: auxR, safeTop: safeTop)
        let inset = IslandMetrics.topInset(safeTop: safeTop, menuBarHeight: 22)
        _ = IslandMetrics.closedSize(topInset: inset, notchWidth: notchW)
        _ = IslandMetrics.expandedSize(topInset: inset, agentCount: 3)
        let wf = IslandMetrics.windowFrame(
            screenFrame: CGRect(x: 0, y: 0, width: screenW, height: screenH), size: ws,
            scale: scale2)

        check(notchW > 100, "notchWidth computed (\(notchW))")
        check(inset == safeTop, "topInset uses safeArea")
        assertCGSizeEqual(ws, IslandMetrics.windowSize(), "window size invariant")
        let midXTol: CGFloat = 0.5
        check(
            abs(wf.midX - screenW / 2) <= midXTol,
            "window centered on screen (midX diff=\(abs(wf.midX - screenW/2)))")
        check(wf.maxY - screenH < 0.01, "window top at screen top")
        check(
            abs(wf.midX - screenW / 2) <= midXTol,
            "symmetric morph: window center does not move (invariant 3)")

        // -- Backing grid alignment (invariant 4)

        let scale1: CGFloat = 1
        let oddScale: CGFloat = 1.5
        for s in [scale1, scale2, oddScale] {
            let f = IslandMetrics.windowFrame(
                screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), size: ws, scale: s)
            let pixel = max(s, 1)
            check((f.minY * pixel).rounded() == (f.minY * pixel), "grid Y at scale \(s)")
            check((f.minX * pixel).rounded() == (f.minX * pixel), "grid X at scale \(s)")
            check((f.width * pixel).rounded() == (f.width * pixel), "grid W at scale \(s)")
            check((f.height * pixel).rounded() == (f.height * pixel), "grid H at scale \(s)")
        }

        // -- Notchless fallback (invariant 5)

        let noNotchW = IslandMetrics.notchWidth(
            screenWidth: 1512, auxLeft: 651, auxRight: 651, safeTop: 0)
        check(noNotchW == IslandMetrics.notchlessFallbackWidth, "notchless fallback \(noNotchW)")

        // -- Oversized notch clamp (invariant 6)

        let bigNotch = IslandMetrics.closedSize(topInset: 47, notchWidth: 999)
        check(
            bigNotch.width == IslandMetrics.expandedWidth,
            "oversized notch clamped to expandedWidth")

        // -- Height cap (invariant 7)

        let manyAgents = IslandMetrics.expandedSize(topInset: 47, agentCount: 50)
        check(
            manyAgents.height == IslandMetrics.maxExpandedHeight,
            "height capped \(manyAgents.height)")

        // -- Zero agents: closed size, not expanded

        let zeroClosed = IslandMetrics.closedSize(topInset: 47, notchWidth: 213)
        check(zeroClosed.height > 0, "closed with 0 agents has height")
        check(
            !IslandMetrics.shouldExpand(hovering: true, hasAgents: false),
            "no expand without agents (invariant 8)")
        check(
            IslandMetrics.shouldCollapse(isExpanded: true, hasAgents: false),
            "collapse when agents empty (invariant 9)")

        // -- Hover-out collapse + approval (invariant 15-16)

        check(
            !IslandMetrics.shouldCollapseOnHoverExit(isExpanded: false, isComposing: false),
            "no collapse on hover-out when already closed")
        check(
            IslandMetrics.shouldCollapseOnHoverExit(isExpanded: true, isComposing: false),
            "collapse on hover-out when expanded")
        check(
            !IslandMetrics.shouldCollapseOnHoverExit(isExpanded: true, isComposing: true),
            "keep expanded while composing prompt")
        check(IslandMetrics.requiresApproval("accessRequest"), "accessRequest requires approval")
        check(IslandMetrics.requiresApproval("access_request"), "access_request requires approval")
        check(!IslandMetrics.requiresApproval("progress"), "progress does not require approval")
        check(!IslandMetrics.requiresApproval("idle"), "idle does not require approval")

        // -- Approval variance

        check(
            ApprovalVariance(rawValue: "yes-no") == .yesNo,
            "variance yes-no decodes")
        check(
            ApprovalVariance(rawValue: "choices") == .choices,
            "variance choices decodes")
        check(
            ApprovalVariance(rawValue: "multi") == .multi,
            "variance multi decodes")
        let noVariance = AgentEvent(
            source: "kilo", kind: .accessRequest, title: nil, message: nil,
            paneId: nil, workspaceId: nil, variance: nil, choices: nil,
            playSound: true, persistent: true)
        check(
            noVariance.effectiveVariance == .yesNo,
            "nil variance defaults to yes-no")
        let multiEvent = AgentEvent(
            source: "kilo", kind: .accessRequest, title: nil, message: nil,
            paneId: "w3:p3", workspaceId: "w3", variance: .multi,
            choices: ["a", "b"], playSound: true, persistent: true)
        check(
            multiEvent.effectiveVariance == .multi && multiEvent.choices?.count == 2,
            "multi variance carries choices")

        // -- Hover state machine (invariant 10-11)

        check(
            IslandMetrics.shouldExpand(hovering: false, hasAgents: true) == false,
            "no expand without hover")
        check(
            IslandMetrics.shouldExpand(hovering: false, hasAgents: false) == false,
            "no expand without hover or agents")
        check(
            IslandMetrics.shouldCollapse(isExpanded: false, hasAgents: false) == false,
            "no collapse when already closed")
        check(
            IslandMetrics.morphStyle(reduceMotion: true) == .linear,
            "reduced motion -> linear (invariant 11)")
        check(
            IslandMetrics.morphStyle(reduceMotion: false) == .spring, "no reduce motion -> spring")
        check(
            IslandMetrics.hoverScale(isHovered: false, isExpanded: true) == 1,
            "no hover -> no scale")
        check(
            abs(IslandMetrics.hoverScale(isHovered: true, isExpanded: false) - 1.02) < 0.001,
            "hover closed scale 1.02")
        check(
            abs(IslandMetrics.hoverScale(isHovered: true, isExpanded: true) - 1.012) < 0.001,
            "hover expanded scale 1.012")

        // -- Top inset fallback chain (invariant 14)

        check(IslandMetrics.topInset(safeTop: 47, menuBarHeight: 22) == 47, "safe top wins")
        check(IslandMetrics.topInset(safeTop: 0, menuBarHeight: 22) == 22, "menu bar fallback")
        check(IslandMetrics.topInset(safeTop: 0, menuBarHeight: 0) == 0, "zero fallback")

        // -- Edge: fractional screen width, content alignment

        let fracW = IslandMetrics.windowFrame(
            screenFrame: CGRect(x: 0, y: 0, width: 1367, height: 800), size: ws, scale: 1)
        check(
            abs(fracW.midX - 1367 / 2) <= midXTol,
            "fractional screen centered (midX diff=\(abs(fracW.midX - 1367/2)))")

        // MARK: - Adversarial (spec-driven: try to break)

        // A1. Status pollution: whitespace/case is not a known status -> no event, no crash.
        var advSeen: [String: AgentEventKind] = [:]
        let weirdStatus = AgentEventManager.update(
            from: [agent("kilo", "Working ", pane: "ad:p1")],
            lastSeenKinds: &advSeen,
            current: nil)
        check(
            weirdStatus.events.isEmpty && weirdStatus.roster.isEmpty,
            "A1 status 'Working ' treated unknown (no event, no crash)")

        // A2. Storm: 100 alternating working/blocked flips emit exactly one per round.
        var storm: [String: AgentEventKind] = [:]
        var stormCurrent: AgentEvent?
        var stormFlips = 0
        for i in 0..<100 {
            let status = (i % 2 == 0) ? "working" : "blocked"
            let out = AgentEventManager.update(
                from: [agent("storm", status, pane: "w3:p3")],
                lastSeenKinds: &storm,
                current: stormCurrent)
            let mine = out.events.filter { $0.paneId == "w3:p3" }
            check(mine.count <= 1, "storm \(i): at most one event per flip (got \(mine.count))")
            if let event = mine.first {
                stormCurrent = event
                stormFlips += 1
            }
        }
        check(stormFlips == 100, "A2 storm: one emission per flip (got \(stormFlips))")
        check(stormCurrent?.kind == .accessRequest, "A2 storm ends on blocked")
        check(stormCurrent?.playSound == true, "A2 storm blocked plays sound")

        // A3. Sharded source (same agent name, two panes); one pane vanishes.
        var advShard: [String: AgentEventKind] = [:]
        _ = AgentEventManager.update(
            from: [
                agent("kilo", "working", pane: "p1"),
                agent("kilo", "working", pane: "p2"),
            ],
            lastSeenKinds: &advShard,
            current: nil)
        let partial = AgentEventManager.update(
            from: [agent("kilo", "working", pane: "p2")],
            lastSeenKinds: &advShard,
            current: nil)
        check(
            !partial.roster.contains { $0.paneId == "p1" },
            "A3 dead pane vanishes from roster: \(partial.roster.map(\.paneId))")
        let revival = AgentEventManager.update(
            from: [
                agent("kilo", "working", pane: "p1"),
                agent("kilo", "working", pane: "p2"),
            ],
            lastSeenKinds: &advShard,
            current: nil)
        check(
            revival.events.allSatisfy { $0.playSound == false },
            "A3 resurrected pane re-appears silently (no ding)")
        check(
            !revival.events.contains(where: { $0.kind == .accessRequest }),
            "A3 resurrected pane never escalates to approval")

        // A4. Degenerate geometry.
        check(
            IslandMetrics.topInset(safeTop: -5, menuBarHeight: 32) == 32,
            "A4 negative safe top falls back to menu bar height")
        let tiny = IslandMetrics.windowFrame(
            screenFrame: CGRect(x: 0, y: 0, width: 400, height: 300), size: ws, scale: 1)
        check(
            tiny.minX >= 0 && tiny.minY >= 0,
            "A4 400x300 screen: window origin non-negative (min=\(tiny.minX),\(tiny.minY))")
        let pixelScale: CGFloat = 8
        let dbgGrid = IslandMetrics.windowFrame(
            screenFrame: CGRect(x: 0, y: 0, width: 1536, height: 960), size: ws, scale: pixelScale)
        check(
            (dbgGrid.minX * pixelScale).rounded() == dbgGrid.minX * pixelScale
                && (dbgGrid.minY * pixelScale).rounded() == dbgGrid.minY * pixelScale,
            "A4 grid aligned at scale 8")
        let overwideNotch = IslandMetrics.notchWidth(
            screenWidth: 400, auxLeft: 300, auxRight: 300, safeTop: 0)
        check(
            overwideNotch <= IslandMetrics.expandedWidth,
            "A4 aux-headed notch clamps below expandedWidth (got \(overwideNotch))")

        // A5. Choices variance without a choices array must not crash or hang.
        let hungryVariance = AgentEvent(
            source: "kilo", kind: .accessRequest, title: nil, message: nil,
            paneId: "p9", workspaceId: "w9", variance: .choices, choices: nil,
            playSound: true, persistent: true)
        check(
            hungryVariance.effectiveVariance == .choices
                || hungryVariance.effectiveVariance == .yesNo,
            "A5 choices variance w/o options decodes safely")

        // L1. Lifecycle controls (plan 001): islandEnabled + snooze persistence.
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            check(cfg.islandEnabled, "L1 default: island enabled")
            check(!cfg.isSnoozed, "L1 default: not snoozed")
            cfg.islandEnabled = false
            cfg.snoozedUntil = Date().addingTimeInterval(600)
            check(!cfg.islandEnabled, "L1: island can be disabled")
            check(cfg.isSnoozed, "L1: snooze within window is active")
            check(
                defaults.object(forKey: "islandEnabled") as? Bool == false,
                "L1: islandEnabled persisted to defaults")
            cfg.snoozedUntil = Date().addingTimeInterval(-10)
            check(!cfg.isSnoozed, "L1: expired snooze is inactive")
            cfg.snoozedUntil = Date().addingTimeInterval(-10)
            check(!cfg.isSnoozed, "L1: expired snooze is inactive")
            let origHidden = cfg.hideAtStartup
            check(cfg.hideAtStartup == false, "L1/L2 default: island not hidden at startup")
            cfg.hideAtStartup = true
            check(
                defaults.object(forKey: "hideAtStartup") as? Bool == true,
                "L2: hideAtStartup persisted")
            cfg.hideAtStartup = origHidden
            cfg.islandEnabled = true
            cfg.snoozedUntil = nil
            defaults.removeObject(forKey: "islandEnabled")
            defaults.removeObject(forKey: "snoozedUntil")
            defaults.removeObject(forKey: "hideAtStartup")
        }

        // L2. LaunchAgent (plan 002): plist detection + launchctl status seam.
        let oldPath = LaunchAgent.plistPath
        let oldRunner = LaunchAgent.processRunner
        let stubPlist = NSTemporaryDirectory() + "/bantay-l2-\(UUID().uuidString).plist"
        LaunchAgent.plistPath = stubPlist
        check(!LaunchAgent.isInstalled, "L2 uninstalled plist not detected")
        FileManager.default.createFile(atPath: stubPlist, contents: Data(), attributes: nil)
        check(LaunchAgent.isInstalled, "L2 installed plist detected")
        LaunchAgent.processRunner = { _ in 0 }
        check(LaunchAgent.isLoaded(), "L2 launchctl exit 0 = loaded")
        LaunchAgent.processRunner = { _ in 1 }
        check(!LaunchAgent.isLoaded(), "L2 launchctl exit 1 = not loaded")
        LaunchAgent.processRunner = { _ in 113 }
        check(!LaunchAgent.isLoaded(), "L2 launchctl exit 113 = not loaded")
        try? FileManager.default.removeItem(atPath: stubPlist)
        check(!LaunchAgent.isInstalled, "L2 removed plist not detected")
        LaunchAgent.plistPath = oldPath
        LaunchAgent.processRunner = oldRunner

        // L3. Idle dock placement (UX fix): side-of-notch geometry + persistence.
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let orig = cfg.islandDockSide
            check(
                cfg.islandDockSide == .right || cfg.islandDockSide == .center,
                "L3 dock default is a valid side or center (got \(cfg.islandDockSide.rawValue))")
            cfg.islandDockSide = .left
            check(
                defaults.string(forKey: "islandDockSide") == "left",
                "L3 dock side persisted")
            cfg.islandDockSide = orig
            defaults.removeObject(forKey: "islandDockSide")
        }
        check(
            IslandMetrics.idleChipWidth > 0
                && IslandMetrics.idleChipWidth < IslandMetrics.expandedWidth,
            "L3 idle chip is compact (got \(IslandMetrics.idleChipWidth))")
        check(
            IslandMetrics.hoverCooldown >= 0.2,
            "L3 hover cooldown long enough to cut accidental expansion (got \(IslandMetrics.hoverCooldown))"
        )
        let shift = IslandMetrics.dockOffset(side: .right, notchWidth: 190, chipWidth: 120)
        check(
            abs(shift - (190 / 2 + IslandMetrics.dockGap + 120 / 2)) < 0.001,
            "L3 right-dock shift math (got \(shift))")
        check(
            abs(IslandMetrics.dockOffset(side: .left, notchWidth: 190, chipWidth: 120)) == shift,
            "L3 left/right dock symmetric")
        let dockedShownBounds = 252 + shift + 120 / 2
        check(
            dockedShownBounds <= IslandMetrics.windowSize().width,
            "L3 idle chip stays on-window when docked (right edge \(dockedShownBounds))")

        // L4. Idle chip sits IN the notch row (flush at the top edge), not below
        // the menu bar — matches the BoringNotch look. Only expansion or the
        // center mode drop under the notch.
        check(
            IslandMetrics.dockGap == 0,
            "L4 idle chip is flush against the notch side (got gap \(IslandMetrics.dockGap))")
        check(
            IslandMetrics.effectiveTopOffset(
                side: .right, isExpanded: false, topInset: 47) == 0,
            "L4 right-dock idle chip sits at the notch level (top inset 0)")
        check(
            IslandMetrics.effectiveTopOffset(
                side: .left, isExpanded: false, topInset: 47) == 0,
            "L4 left-dock idle chip sits at the notch level (top inset 0)")
        check(
            IslandMetrics.effectiveTopOffset(
                side: .center, isExpanded: false, topInset: 47) == 47,
            "L4 center idle mode keeps dropping under the notch")
        check(
            IslandMetrics.effectiveTopOffset(
                side: .right, isExpanded: true, topInset: 47) == 47,
            "L4 expanded panel keeps dropping under the menu bar")

        // L5. Idle agent strip: live work facets beside the notch — style,
        // truncation, width clamps, and config persistence.
        check(
            IslandMetrics.idleDefaultMaxChips == 3,
            "L5 default max chips is 3 (got \(IslandMetrics.idleDefaultMaxChips))")
        check(
            IslandMetrics.idleShownChips(agentCount: 2, maxChips: 3) == 2,
            "L5 fewer agents than cap shows all")
        check(
            IslandMetrics.idleShownChips(agentCount: 7, maxChips: 3) == 3,
            "L5 more agents than cap truncates to cap")
        check(
            IslandMetrics.idleShownChips(agentCount: 0, maxChips: 3) == 0,
            "L5 empty roster shows nothing")
        let single = IslandMetrics.idleNameChipWidth(nameLength: 4)
        let nine = IslandMetrics.idleNameChipWidth(nameLength: 40)
        check(nine > single, "L5 longer names widen chips")
        check(
            abs(nine - IslandMetrics.idleNameChipWidth(nameLength: 1000)) < 40,
            "L5 name width is clamped (got \(nine))")
        let s3 = IslandMetrics.idleStripWidth(
            style: .names, agentCount: 3, maxChips: 3,
            nameLengths: [4, 4, 4])
        let s5 = IslandMetrics.idleStripWidth(
            style: .names, agentCount: 5, maxChips: 3,
            nameLengths: [4, 4, 4, 4, 4])
        check(s5 > s3, "L5 overflow adds width for +N (got \(s5) vs \(s3))")
        let dots1 = IslandMetrics.idleStripWidth(
            style: .dots, agentCount: 1, maxChips: 3, nameLengths: [])
        let dotsCapped = IslandMetrics.idleStripWidth(
            style: .dots, agentCount: 12, maxChips: 6, nameLengths: [])
        check(dotsCapped >= dots1, "L5 dots style width grows with agents")
        check(
            dotsCapped <= IslandMetrics.idleDotsChipWidth(dotCount: 6) + 1,
            "L5 dots capped at 6 dots")
        let sumW = IslandMetrics.idleStripWidth(
            style: .summary, agentCount: 9, maxChips: 6, nameLengths: [])
        check(sumW > 0 && sumW < IslandMetrics.expandedWidth, "L5 summary width sane")
        let closedNames = IslandMetrics.idleClosedWidth(
            style: .names, agentCount: 8, maxChips: 6,
            nameLengths: Array(repeating: 4, count: 8), notchWidth: 190)
        check(closedNames >= IslandMetrics.idleChipWidth, "L5 closed idle never narrower than pill")
        check(
            closedNames <= IslandMetrics.expandedWidth && closedNames <= 190,
            "L5 closed idle clamps to notch width (\(closedNames))")
        let closedEmpty = IslandMetrics.idleClosedWidth(
            style: .names, agentCount: 0, maxChips: 3, nameLengths: [], notchWidth: 190)
        check(closedEmpty >= IslandMetrics.idleChipWidth, "L5 empty roster uses pill min width")

        // L5. Idle facets persist and clamp.
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let origStyle = cfg.idleStyle
            let origChips = cfg.idleMaxChips
            check(
                cfg.clampedIdleMaxChips >= 1 && cfg.clampedIdleMaxChips <= 6,
                "L5 clamped max chips in range (got \(cfg.clampedIdleMaxChips))")
            cfg.idleStyle = .dots
            check(
                defaults.string(forKey: "idleStyle") == "dots",
                "L5 idle style persisted")
            cfg.idleMaxChips = 7
            check(
                cfg.clampedIdleMaxChips == 6,
                "L5 max chips clamped at 6 (got \(cfg.clampedIdleMaxChips))")
            cfg.idleMaxChips = 0
            check(
                cfg.clampedIdleMaxChips == 1,
                "L5 max chips clamped at 1 (got \(cfg.clampedIdleMaxChips))")
            cfg.idleMaxChips = 4
            check(
                defaults.integer(forKey: "idleMaxChips") == 4,
                "L5 max chips persisted after clamp rewrites")
            cfg.idleStyle = origStyle
            cfg.idleMaxChips = origChips
            defaults.removeObject(forKey: "idleStyle")
            defaults.removeObject(forKey: "idleMaxChips")
        }

        // L6. Expanded control plane: counts, queue split, group order,
        // queue-aware height, multiplexer detection + adapter verbs.
        let mixedKinds: [AgentEventKind] = [
            .progress, .accessRequest, .completed, .waiting, .failed, .idle, .started,
        ]
        let counts = IslandMetrics.agentCounts(kinds: mixedKinds)
        check(counts.needsInput == 2, "L6 needs-input count (got \(counts.needsInput))")
        check(counts.working == 2, "L6 working count (got \(counts.working))")
        check(counts.done == 1, "L6 done count (got \(counts.done))")
        check(counts.error == 1, "L6 error count (got \(counts.error))")
        check(counts.idle == 1, "L6 idle count (got \(counts.idle))")
        check(counts.total == 7, "L6 total counts (got \(counts.total))")
        check(
            IslandMetrics.agentCounts(kinds: []).total == 0,
            "L6 empty roster counts zero")
        let split = IslandMetrics.queueSplit(blockedCount: 7, cap: 3)
        check(split.shown == 3 && split.overflow == 4, "L6 queue split 3+4 (got \(split))")
        let splitSmall = IslandMetrics.queueSplit(blockedCount: 2, cap: 3)
        check(
            splitSmall.shown == 2 && splitSmall.overflow == 0,
            "L6 queue split shows all when under cap (got \(splitSmall))")
        check(
            IslandMetrics.queueSplit(blockedCount: 9, cap: 0).shown == 1,
            "L6 queue cap floors at 1")
        check(
            IslandMetrics.expandedGroupRank(.accessRequest) == 0
                && IslandMetrics.expandedGroupRank(.waiting) == 0,
            "L6 needs-input ranks first")
        check(
            IslandMetrics.expandedGroupRank(.progress) < IslandMetrics.expandedGroupRank(.completed),
            "L6 working before done")
        check(
            IslandMetrics.expandedGroupRank(.failed) < IslandMetrics.expandedGroupRank(.idle),
            "L6 failed before idle")
        let hNoQueue = IslandMetrics.expandedSize(topInset: 47, agentCount: 3)
        let hQueue = IslandMetrics.expandedSize(topInset: 47, agentCount: 3, queueCount: 2)
        check(hQueue.height > hNoQueue.height, "L6 queue adds height (got \(hQueue.height) vs \(hNoQueue.height))")
        check(
            hQueue.height <= IslandMetrics.maxExpandedHeight,
            "L6 queue-aware height capped (got \(hQueue.height))")
        let contentQueue = IslandMetrics.contentHeight(
            isExpanded: true, topInset: 47, agentCount: 3, queueCount: 2)
        check(
            abs(contentQueue - (hQueue.height - 47)) < 0.01,
            "L6 content height excludes top inset")
        check(
            IslandMetrics.expandedGroupRank(.cancelled) == 4
                && IslandMetrics.expandedGroupRank(.clear) == 4,
            "L6 cancelled/clear idle-ish")

        // L6. Multiplexer detection (pure, env-injected).
        check(
            PlexerDetection.detect(env: ["HERDR_ENV": "1"]) == .herdr,
            "L6 HERDR_ENV detects herdr")
        check(
            PlexerDetection.detect(env: [:], herdrSocketExists: true) == .herdr,
            "L6 herdr socket detects herdr")
        check(
            PlexerDetection.detect(env: ["TMUX": "/private/tmp/tmux-501/default,1,0"]) == .tmux,
            "L6 TMUX env detects tmux")
        check(
            PlexerDetection.detect(env: [:], tmuxSocketExists: true) == .tmux,
            "L6 tmux socket detects tmux")
        check(
            PlexerDetection.detect(env: ["ZELLIJ": "1"]) == .zellij,
            "L6 ZELLIJ env detects zellij")
        check(
            PlexerDetection.detect(env: [:]) == nil,
            "L6 no multiplexer detected")
        check(
            PlexerDetection.detect(env: ["HERDR_ENV": "0"], herdrBinaryExists: false) == nil,
            "L6 herdr socket without binary is ignored")
        check(PlexerKind.herdr.label == "herdr", "L6 herdr label")
        check(PlexerKind.tmux.label == "tmux", "L6 tmux label")
        check(PlexerKind.zellij.label == "zellij", "L6 zellij label")

        // L6. Expanded facets persist + clamp.
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let origCap = cfg.expandedQueueCap
            let origShow = cfg.expandedShowQueue
            let origGroup = cfg.expandedGroupByState
            check(
                cfg.clampedExpandedQueueCap >= 1 && cfg.clampedExpandedQueueCap <= 5,
                "L6 queue cap clamped in range (got \(cfg.clampedExpandedQueueCap))")
            cfg.expandedQueueCap = 9
            check(
                cfg.clampedExpandedQueueCap == 5,
                "L6 queue cap clamps at 5 (got \(cfg.clampedExpandedQueueCap))")
            cfg.expandedQueueCap = 2
            check(
                defaults.integer(forKey: "expandedQueueCap") == 2,
                "L6 queue cap persisted")
            cfg.expandedShowQueue = false
            check(
                defaults.bool(forKey: "expandedShowQueue") == false,
                "L6 queue toggle persisted")
            cfg.expandedGroupByState = false
            check(
                defaults.bool(forKey: "expandedGroupByState") == false,
                "L6 grouping toggle persisted")
            cfg.expandedQueueCap = origCap
            cfg.expandedShowQueue = origShow
            cfg.expandedGroupByState = origGroup
            defaults.removeObject(forKey: "expandedQueueCap")
            defaults.removeObject(forKey: "expandedShowQueue")
            defaults.removeObject(forKey: "expandedGroupByState")
        }

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)

    }
}
