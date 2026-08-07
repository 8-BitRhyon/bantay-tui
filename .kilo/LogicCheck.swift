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
                terminalTitle: "\(name) | \(status)", cwd: nil)
        }

        func expectKinds(_ events: [AgentEvent], _ kinds: [AgentEventKind], _ name: String) {
            check(events.map(\.kind) == kinds, "\(name): \(events.map(\.kind)) != \(kinds)")
        }

        func dateWith(minutesSinceMidnight minutes: Int) -> Date {
            let cal = Calendar.current
            let start = cal.startOfDay(for: Date())
            return cal.date(byAdding: .minute, value: minutes, to: start) ?? Date()
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
                side: .center, isExpanded: false, topInset: 47) == 0,
            "L4 center idle mode sits in the notch row (behind the notch)")
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
            IslandMetrics.expandedGroupRank(.progress)
                < IslandMetrics.expandedGroupRank(.completed),
            "L6 working before done")
        check(
            IslandMetrics.expandedGroupRank(.failed) < IslandMetrics.expandedGroupRank(.idle),
            "L6 failed before idle")
        let hNoQueue = IslandMetrics.expandedSize(topInset: 47, agentCount: 3)
        let hQueue = IslandMetrics.expandedSize(topInset: 47, agentCount: 3, queueCount: 2)
        check(
            hQueue.height > hNoQueue.height,
            "L6 queue adds height (got \(hQueue.height) vs \(hNoQueue.height))")
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

        // L7. In-UI approvals: ApprovalControls model + snapshot merge.
        let yesNo = IslandMetrics.ApprovalControls.make(variance: nil, choices: nil)
        check(yesNo.isYesNo, "L7 nil variance defaults to yes/no")
        check(
            IslandMetrics.ApprovalControls.make(variance: .yesNo, choices: ["a", "b"]).isYesNo,
            "L7 explicit yes-no ignores choices")
        check(yesNo.optionLabels.isEmpty, "L7 yes-no has no option buttons")
        let singleChoice = IslandMetrics.ApprovalControls.make(
            variance: .choices, choices: ["Build", "Test", "Skip"])
        check(
            !singleChoice.isYesNo && !singleChoice.isMulti, "L7 choices is neither yes-no nor multi"
        )
        check(
            singleChoice.optionLabels == ["1", "2", "3"],
            "L7 choices renders numbered options (got \(singleChoice.optionLabels))")
        check(
            IslandMetrics.ApprovalControls.optionNumber(forIndex: 2) == 3,
            "L7 option number is 1-based")
        let multi = IslandMetrics.ApprovalControls.make(
            variance: .multi, choices: ["a", "b", "c"])
        check(multi.isMulti, "L7 multi variance detected")
        check(
            multi.optionLabels.count == 3,
            "L7 multi renders numbered options (got \(multi.optionLabels))")
        check(multi.submitLabel == "Submit", "L7 multi submit label")
        let toggled1 = IslandMetrics.ApprovalControls.toggling([], index: 0)
        check(toggled1 == [1], "L7 toggling adds option 1 (got \(toggled1))")
        let toggled2 = IslandMetrics.ApprovalControls.toggling(toggled1, index: 2)
        check(toggled2 == [1, 3], "L7 toggling adds option 3 (got \(toggled2))")
        let toggled3 = IslandMetrics.ApprovalControls.toggling(toggled2, index: 0)
        check(toggled3 == [3], "L7 toggling removes option 1 (got \(toggled3))")
        check(
            IslandMetrics.ApprovalControls.selectionNumbers([3, 1, 2]) == [1, 2, 3],
            "L7 selection numbers sorted 1-based")
        check(
            IslandMetrics.ApprovalControls.selectionNumbers([]).isEmpty,
            "L7 empty selection sends nothing")
        let emptyChoices = IslandMetrics.ApprovalControls.make(variance: .choices, choices: nil)
        check(
            emptyChoices.isYesNo,
            "L7 choices with no options falls back to yes/no")

        // L7. Snapshot approval merge: blocked agents carry variance/choices.
        MainActor.assumeIsolated {
            let info = HerdrAgentInfo(
                agent: "kilo", agentStatus: "blocked", paneId: "1-1",
                workspaceId: "1", terminalTitle: "Need approval: run tests?", cwd: nil)
            guard let snapshot = AgentEventManager.snapshot(for: info) else {
                check(false, "L7 blocked snapshot builds")
                return
            }
            check(snapshot.kind == .accessRequest, "L7 blocked maps to accessRequest")
            check(snapshot.variance == nil, "L7 raw snapshot has no variance yet")
            check(snapshot.approval.isYesNo, "L7 raw snapshot defaults to yes/no")

            let manager = AgentEventManager(
                eventsFileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("lc-l7-\(UUID().uuidString).jsonl"),
                capture: false)
            manager.pendingApprovals["1-1"] = (
                variance: .multi, choices: ["lint", "test", "deploy"]
            )
            let merged = manager.mergeApprovals(into: [snapshot])
            guard let m = merged.first else {
                check(false, "L7 merged roster non-empty")
                return
            }
            check(m.variance == .multi, "L7 merge attaches multi variance")
            check(m.choices == ["lint", "test", "deploy"], "L7 merge attaches choices")
            check(m.approval.isMulti, "L7 merged snapshot is multi")
            check(
                m.approval.optionLabels == ["1", "2", "3"],
                "L7 merged snapshot renders numbered options")
            let plain = HerdrAgentInfo(
                agent: "shell", agentStatus: "idle", paneId: "1-2",
                workspaceId: "1", terminalTitle: nil, cwd: nil)
            let plainSnapshot = AgentEventManager.snapshot(for: plain)!
            let unmerged = manager.mergeApprovals(into: [plainSnapshot])
            check(
                unmerged[0].variance == nil && unmerged[0].choices == nil,
                "L7 idle agents never carry approval data")
        }

        // L8. Speed & peripheral-vision snacks: elapsed labels, shortcut
        // keys, startedAt merge, snooze-until-restart, new config facets.
        let base = Date(timeIntervalSince1970: 1_000_000)
        check(
            IslandMetrics.elapsedLabel(since: base, now: base.addingTimeInterval(14)) == "14s",
            "L8 elapsed under a minute in seconds (got \(IslandMetrics.elapsedLabel(since: base, now: base.addingTimeInterval(14))))"
        )
        check(
            IslandMetrics.elapsedLabel(since: base, now: base.addingTimeInterval(125)) == "2m",
            "L8 elapsed in minutes (got \(IslandMetrics.elapsedLabel(since: base, now: base.addingTimeInterval(125))))"
        )
        check(
            IslandMetrics.elapsedLabel(since: base, now: base.addingTimeInterval(3600)) == "1h",
            "L8 elapsed exactly one hour (got \(IslandMetrics.elapsedLabel(since: base, now: base.addingTimeInterval(3600))))"
        )
        check(
            IslandMetrics.elapsedLabel(since: base, now: base.addingTimeInterval(4500))
                == "1h15m",
            "L8 elapsed hours+minutes (got \(IslandMetrics.elapsedLabel(since: base, now: base.addingTimeInterval(4500))))"
        )
        check(
            IslandMetrics.elapsedLabel(since: base, now: base.addingTimeInterval(-5)) == "0s",
            "L8 negative elapsed clamps to 0s")
        check(
            IslandMetrics.shortcutKey(for: "y") == .approve,
            "L8 y maps to approve")
        check(
            IslandMetrics.shortcutKey(for: "N") == .deny,
            "L8 N maps to deny")
        check(
            IslandMetrics.shortcutKey(for: "3") == .option(3),
            "L8 digit maps to option")
        check(
            IslandMetrics.shortcutKey(for: "x") == nil,
            "L8 unknown key ignored")
        check(IslandMetrics.glowBlockedColor == "#ffe066", "L8 glow amber constant")
        check(IslandMetrics.glowUrgentColor == "#ff6b6b", "L8 glow red constant")

        // L8. startedAt merge: working agents carry burst start, done do not.
        MainActor.assumeIsolated {
            let manager = AgentEventManager(
                eventsFileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("lc-l8-\(UUID().uuidString).jsonl"),
                capture: false)
            let working = AgentSnapshot(
                id: "p1", source: "kilo", kind: .progress, title: nil, message: nil,
                paneId: "1-1", workspaceId: nil, cwd: nil, variance: nil, choices: nil,
                startedAt: nil,
                projectContext: nil)
            let done = AgentSnapshot(
                id: "p2", source: "codex", kind: .completed, title: nil, message: nil,
                paneId: "1-2", workspaceId: nil, cwd: nil, variance: nil, choices: nil,
                startedAt: nil,
                projectContext: nil)
            let start = Date(timeIntervalSince1970: 500_000)
            manager.pendingApprovals["1-1"] = (variance: nil, choices: nil)
            let merged = manager.mergeApprovals(into: [working, done])
            check(
                merged[0].startedAt == nil,
                "L8 no start time yet (merged \(String(describing: merged[0].startedAt)))")

            // Simulate the showEvent tracking by recording burst start.
            manager.recordStartForTesting(pane: "1-1", at: start)
            let merged2 = manager.mergeApprovals(into: [working, done])
            check(
                merged2[0].startedAt == start,
                "L8 working agent carries burst start")
            check(
                merged2[1].startedAt == nil,
                "L8 done agent never carries start time")
            manager.clearStartForTesting(pane: "1-1")
            let merged3 = manager.mergeApprovals(into: [working])
            check(
                merged3[0].startedAt == nil,
                "L8 cleared burst drops start time")
        }

        // L8. New facets persist; snooze-until-restart counts as snoozed.
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let orig = (
                cfg.globalHotkeyEnabled, cfg.keyboardShortcuts, cfg.edgeGlowEnabled,
                cfg.showElapsedTime, cfg.menuBarBadge, cfg.snoozeUntilRestart
            )
            check(cfg.globalHotkeyEnabled, "L8 hotkey default on")
            check(cfg.keyboardShortcuts, "L8 keyboard shortcuts default on")
            check(cfg.edgeGlowEnabled, "L8 edge glow default on")
            check(cfg.showElapsedTime, "L8 elapsed default on")
            check(cfg.menuBarBadge, "L8 menu badge default on")
            cfg.globalHotkeyEnabled = false
            check(
                defaults.bool(forKey: "globalHotkeyEnabled") == false,
                "L8 hotkey persisted")
            cfg.snoozeUntilRestart = true
            check(cfg.isSnoozed, "L8 snooze-until-restart is snoozed")
            cfg.snoozeUntilRestart = false
            cfg.snoozedUntil = nil
            check(!cfg.isSnoozed, "L8 cleared snooze is not snoozed")
            cfg.globalHotkeyEnabled = orig.0
            cfg.keyboardShortcuts = orig.1
            cfg.edgeGlowEnabled = orig.2
            cfg.showElapsedTime = orig.3
            cfg.menuBarBadge = orig.4
            cfg.snoozeUntilRestart = orig.5
            defaults.removeObject(forKey: "globalHotkeyEnabled")
            defaults.removeObject(forKey: "keyboardShortcuts")
            defaults.removeObject(forKey: "edgeGlowEnabled")
            defaults.removeObject(forKey: "showElapsedTime")
            defaults.removeObject(forKey: "menuBarBadge")
            defaults.removeObject(forKey: "snoozeUntilRestart")
        }

        // L9. Standalone agent detection: classification, herdr filtering,
        // transcript tailing, and scanner merging.
        check(
            AgentDetector.canonicalName(forProcess: "claude") == "claude",
            "L9 claude classified")
        check(
            AgentDetector.canonicalName(forProcess: "codex") == "codex",
            "L9 codex classified")
        check(
            AgentDetector.canonicalName(forProcess: "cursor-agent") == "cursor",
            "L9 cursor-agent classified")
        check(
            AgentDetector.canonicalName(forProcess: "gemini-cli") == "gemini",
            "L9 gemini-cli classified")
        check(
            AgentDetector.canonicalName(forProcess: "opencode") == "opencode",
            "L9 opencode classified")
        check(
            AgentDetector.canonicalName(forProcess: "bash") == nil,
            "L9 shell not an agent")
        check(
            AgentDetector.canonicalName(forProcess: "Claude") == "claude",
            "L9 classification case-insensitive")
        check(
            AgentDetector.isHerdrManaged(environmentLines: ["HERDR_ENV=1", "PATH=/usr/bin"]),
            "L9 herdr env detected")
        check(
            !AgentDetector.isHerdrManaged(environmentLines: ["PATH=/usr/bin"]),
            "L9 plain env not herdr")
        check(
            AgentDetector.transcriptSearchPaths(home: "/tmp/x", name: "claude").first
                == "/tmp/x/.claude/projects",
            "L9 claude transcript path")
        check(
            AgentDetector.transcriptSearchPaths(home: "/tmp/x", name: "codex").first
                == "/tmp/x/.codex/sessions",
            "L9 codex transcript path")
        check(
            AgentDetector.transcriptSearchPaths(home: "/tmp/x", name: "unknown").isEmpty,
            "L9 unknown agent has no transcript path")

        // L9. Transcript tailing picks the newest jsonl line.
        let transcriptDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-l9-\(UUID().uuidString)")
        let projects = transcriptDir.appendingPathComponent(".claude/projects")
        try? FileManager.default.createDirectory(
            at: projects, withIntermediateDirectories: true)
        let old = projects.appendingPathComponent("old.jsonl")
        let new = projects.appendingPathComponent("new.jsonl")
        try? """
        {"type":"assistant","message":{"content":"first step"}}
        {"type":"assistant","message":{"content":"second step"}}
        """.write(to: old, atomically: true, encoding: .utf8)
        try? """
        {"type":"assistant","message":{"content":"latest activity line"}}
        """.write(to: new, atomically: true, encoding: .utf8)
        let activity = AgentDetector.latestActivity(root: projects.path)
        check(
            activity?.contains("latest activity") == true,
            "L9 latest transcript line surfaced (got \(String(describing: activity)))")

        // L9. Scanner: classifies samples, skips herdr-managed + shells.
        let samples = [
            ProcessSample(
                pid: 101, name: "claude", command: "claude", environmentLines: []),
            ProcessSample(
                pid: 202, name: "codex", command: "codex",
                environmentLines: ["HERDR_ENV=1"]),
            ProcessSample(pid: 303, name: "zsh", command: "zsh", environmentLines: []),
        ]
        let detected = StandaloneAgentScanner.detect(samples: samples, home: transcriptDir.path)
        check(
            detected.count == 1,
            "L9 scanner keeps standalone claude only (got \(detected.map(\.name)))")
        check(detected.first?.name == "claude", "L9 detected agent name")
        check(detected.first?.pid == 101, "L9 detected agent pid")
        check(
            detected.first?.activity?.contains("latest activity") == true,
            "L9 detected agent carries activity")
        check(
            StandaloneAgentScanner.detect(samples: [], home: transcriptDir.path).isEmpty,
            "L9 empty scan yields nothing")

        // L9. Roster merge: herdr-managed agents are not duplicated; config
        // toggle persists.
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let orig = cfg.standaloneScanEnabled
            check(cfg.standaloneScanEnabled, "L9 standalone scan default on")
            cfg.standaloneScanEnabled = false
            check(
                defaults.bool(forKey: "standaloneScanEnabled") == false,
                "L9 standalone toggle persisted")
            cfg.standaloneScanEnabled = orig
            defaults.removeObject(forKey: "standaloneScanEnabled")

            let manager = AgentEventManager(
                eventsFileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("lc-l9m-\(UUID().uuidString).jsonl"),
                capture: false)
            let herdr = [
                HerdrAgentInfo(
                    agent: "claude", agentStatus: "working", paneId: "1-1",
                    workspaceId: "1", terminalTitle: "refactor", cwd: nil)
            ]
            let merged = manager.mergeStandalone(into: herdr, detected: detected)
            check(
                merged.count == 1 && merged[0].paneId == "1-1",
                "L9 herdr claude not duplicated by standalone scan (got \(merged.count))")
            let noHerdr = manager.mergeStandalone(into: [], detected: detected)
            check(
                noHerdr.count == 1 && noHerdr[0].agent == "claude",
                "L9 standalone agent surfaces when herdr has none (got \(noHerdr.map(\.agent)))")
            check(
                noHerdr[0].agentStatus == "working" && noHerdr[0].paneId == nil,
                "L9 standalone info mapped")
        }

        // L10. Usage gauge: transcript parsing (claude + codex shapes),
        // aggregation, budget fraction, compact tokens, config facets.
        let claudeLine =
            #"{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":300,"cache_creation_input_tokens":50},"costUSD":0.012}}"#
        let flatLine =
            #"{"type":"response_item","usage":{"input_tokens":500,"output_tokens":100},"costUSD":0.004}"#
        guard let claudeUsage = UsageParser.parse(jsonLine: claudeLine) else {
            check(false, "L10 claude usage parses")
            fatalError()
        }
        check(
            claudeUsage.inputTokens == 1000,
            "L10 claude input tokens (got \(claudeUsage.inputTokens))")
        check(claudeUsage.outputTokens == 200, "L10 claude output tokens")
        check(claudeUsage.cacheReadTokens == 300, "L10 claude cache read")
        check(claudeUsage.cacheCreationTokens == 50, "L10 claude cache creation")
        check(abs(claudeUsage.costUSD - 0.012) < 0.0001, "L10 claude cost parsed")
        guard let flatUsage = UsageParser.parse(jsonLine: flatLine) else {
            check(false, "L10 flat usage parses")
            fatalError()
        }
        check(flatUsage.inputTokens == 500, "L10 flat input tokens")
        check(flatUsage.outputTokens == 100, "L10 flat output tokens")
        check(abs(flatUsage.costUSD - 0.004) < 0.0001, "L10 flat cost parsed")
        check(
            UsageParser.parse(jsonLine: #"{"type":"assistant","message":{"content":"hi"}}"#)
                == nil,
            "L10 line without usage ignored")
        let summed = UsageParser.parseAll(lines: [claudeLine, flatLine, "garbage"])
        check(summed.inputTokens == 1500, "L10 parseAll sums input (got \(summed.inputTokens))")
        check(summed.outputTokens == 300, "L10 parseAll sums output")
        check(
            abs(summed.costUSD - 0.016) < 0.0001,
            "L10 parseAll sums cost (got \(summed.costUSD))")
        check(
            UsageTracker.aggregate([claudeUsage, flatUsage]).totalTokens == 2150,
            "L10 aggregate totals (got \(UsageTracker.aggregate([claudeUsage, flatUsage]).totalTokens))"
        )
        check(
            abs(UsageTracker.fractionUsed(costUSD: 5, budgetUSD: 10) - 0.5) < 0.001,
            "L10 fraction half budget")
        check(
            abs(UsageTracker.fractionUsed(costUSD: 20, budgetUSD: 10) - 1) < 0.001,
            "L10 fraction clamps at 1")
        check(
            abs(UsageTracker.fractionUsed(costUSD: -3, budgetUSD: 10) - 0) < 0.001,
            "L10 fraction clamps at 0")
        check(UsageTracker.fractionUsed(costUSD: 2, budgetUSD: 0) == 0, "L10 zero budget safe")
        check(
            UsageTracker.compactTokens(1234) == "1.2k",
            "L10 compact k (got \(UsageTracker.compactTokens(1234)))")
        check(UsageTracker.compactTokens(3_500_000) == "3.5m", "L10 compact m")
        check(UsageTracker.compactTokens(42) == "42", "L10 compact small")

        // L10. Config facets: gauge default on, budget clamped + persisted.
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let origGauge = cfg.showUsageGauge
            let origBudget = cfg.usageBudgetUSD
            check(cfg.showUsageGauge, "L10 usage gauge default on")
            cfg.showUsageGauge = false
            check(defaults.bool(forKey: "showUsageGauge") == false, "L10 gauge persisted")
            cfg.usageBudgetUSD = 500
            check(cfg.usageBudgetUSD == 100, "L10 budget clamps at 100 (got \(cfg.usageBudgetUSD))")
            cfg.usageBudgetUSD = 0.5
            check(cfg.usageBudgetUSD == 1, "L10 budget clamps at 1 (got \(cfg.usageBudgetUSD))")
            cfg.usageBudgetUSD = 25
            check(defaults.double(forKey: "usageBudgetUSD") == 25, "L10 budget persisted")
            cfg.showUsageGauge = origGauge
            cfg.usageBudgetUSD = origBudget
            defaults.removeObject(forKey: "showUsageGauge")
            defaults.removeObject(forKey: "usageBudgetUSD")
        }

        // L11. Remote ingest (SSH bridge): HTTP parsing, payload
        // validation, file append, port clamping, config persistence.
        let postBody =
            #"{"type":"access_request","title":"remote prompt","paneId":"r1","variance":"choices","choices":["a","b"]}"#
        let postData = Data(
            ("POST /events HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(postBody.utf8.count)\r\n\r\n\(postBody)").utf8)
        guard let request = IngestHTTP.request(from: postData) else {
            check(false, "L11 POST request parses")
            fatalError()
        }
        check(request.method == "POST", "L11 method is POST")
        check(
            String(data: request.body, encoding: .utf8) == postBody,
            "L11 body extracted by content-length")
        check(
            IngestHTTP.request(from: Data("POST /events HTTP/1.1\r\n\r\n".utf8)) == nil,
            "L11 missing content-length ignored")
        check(
            IngestHTTP.request(from: Data("GET /events HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8))
                == nil,
            "L11 non-POST rejected")
        check(
            IngestHTTP.request(
                from: Data("POST /events HTTP/1.1\r\nContent-Length: 10\r\n\r\nab".utf8))
                == nil,
            "L11 truncated body rejected")
        check(IngestHTTP.clampedPort(80) == 1024, "L11 port floors at 1024")
        check(IngestHTTP.clampedPort(70000) == 65535, "L11 port caps at 65535")
        check(IngestHTTP.clampedPort(41817) == 41817, "L11 port passthrough")
        check(
            !IngestHTTP.okResponse().isEmpty && !IngestHTTP.badResponse().isEmpty,
            "L11 responses present")

        // L64. Ingest auth token (security sweep MEDIUM-1): the shared secret
        // is required on every ingest request, compared constant-time, and the
        // hook command + matchers tolerate the `?token=` query string.
        do {
            let token = NotchHUDConfig.generateIngestToken()
            check(token.utf8.count == 32, "L64 generated token is 128-bit hex")
            let tokenData = Data(
                ("POST /events?token=\(token) HTTP/1.1\r\nHost: localhost\r\n"
                    + "Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}").utf8)
            let withToken = IngestHTTP.request(from: tokenData)
            check(withToken?.token == token, "L64 request parses token query param")
            let noTokenData = Data(
                ("POST /events HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
                    + "Content-Length: 2\r\n\r\n{}").utf8)
            let withoutToken = IngestHTTP.request(from: noTokenData)
            check(withoutToken?.token == nil, "L64 no query means no token")
            check(
                NotchHUDConfig.tokenMatches(token, expected: token),
                "L64 matching token compares equal")
            // Flip the first char to a value that is guaranteed to differ:
            // the previous `"a" + dropFirst()` collided (and flaked) when the
            // random token already started with "a".
            let wrong = (token.first == "a" ? "b" : "a") + String(token.dropFirst())
            check(
                !NotchHUDConfig.tokenMatches(wrong, expected: token),
                "L64 wrong token rejected")
            check(
                !NotchHUDConfig.tokenMatches("short", expected: token),
                "L64 short token rejected (length guard)")
            check(
                !NotchHUDConfig.tokenMatches("", expected: token),
                "L64 empty token rejected")
            let tokenCommand = ClaudeHookInstaller.hookCommand(port: 41817, token: token)
            check(
                tokenCommand.contains("token=\(token)"),
                "L64 hook command embeds token")
            check(
                ClaudeHookInstaller.isBantayHook(["command": tokenCommand]),
                "L64 matcher accepts token'd hook command")
            check(
                ClaudeHookInstaller.isOwnedBantayHook(["command": tokenCommand]),
                "L64 owned matcher accepts token'd hook command")
            check(
                LaunchAgent.xmlEscape("/Users/me/App & Tools/app")
                    == "/Users/me/App &amp; Tools/app",
                "L64 xmlEscape escapes ampersand")
            check(
                LaunchAgent.xmlEscape("/a<b>c") == "/a&lt;b&gt;c",
                "L64 xmlEscape escapes angle brackets")
            check(
                LaunchAgent.xmlEscape("/q\"u'ote") == "/q&quot;u&apos;ote",
                "L64 xmlEscape escapes quotes")
            check(
                LaunchAgent.plistContent(binaryPath: "/a&b/c", dataDir: "/d<e").contains("&amp;"),
                "L64 plist escapes binary path")
        }

        // L11. Ingest appends valid payloads to the watched events file.
        MainActor.assumeIsolated {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("lc-l11-\(UUID().uuidString).jsonl")
            let manager = AgentEventManager(eventsFileURL: url, capture: false)
            manager.ingestEventLine("not json at all")
            manager.ingestEventLine(postBody)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            check(
                text.contains("access_request") && !text.contains("not json"),
                "L11 only valid payloads appended")

            // L11. Config: ingest off by default, port clamped + persisted.
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let origEnabled = cfg.ingestEnabled
            let origPort = cfg.ingestPort
            check(!cfg.ingestEnabled, "L11 ingest default off (secure)")
            check(cfg.ingestPort == 41817, "L11 default port 41817")
            cfg.ingestEnabled = true
            check(defaults.bool(forKey: "ingestEnabled"), "L11 ingest persisted")
            cfg.ingestPort = 70000
            check(cfg.ingestPort == 65535, "L11 port clamps on set (got \(cfg.ingestPort))")
            cfg.ingestPort = 42000
            check(defaults.integer(forKey: "ingestPort") == 42000, "L11 port persisted")
            cfg.ingestEnabled = origEnabled
            cfg.ingestPort = origPort
            defaults.removeObject(forKey: "ingestEnabled")
            defaults.removeObject(forKey: "ingestPort")
        }

        // L13. Shelf: clipboard history + file drops (dedup, ordering, limits)
        // and config facets.
        let t0 = Date(timeIntervalSince1970: 1_000)
        let emptyClip = ClipboardHistory.merging(existing: [], newText: "   ", now: t0, limit: 5)
        check(emptyClip.isEmpty, "L13 whitespace clipboard ignored")
        let c1 = ClipboardHistory.merging(existing: [], newText: "hello", now: t0, limit: 5)
        check(c1.count == 1 && c1[0].text == "hello", "L13 first clip added")
        let c2 = ClipboardHistory.merging(
            existing: c1, newText: "world", now: t0.addingTimeInterval(5), limit: 5)
        check(c2.count == 2 && c2[0].text == "world", "L13 newest first")
        let c3 = ClipboardHistory.merging(
            existing: c2, newText: "hello", now: t0.addingTimeInterval(10), limit: 5)
        check(
            c3.count == 2 && c3[0].text == "hello",
            "L13 re-copy moves to front (got \(c3.map(\.text)))")
        var capped = [ClipboardItem]()
        for i in 0..<10 {
            capped = ClipboardHistory.merging(
                existing: capped, newText: "item\(i)", now: t0.addingTimeInterval(Double(i)),
                limit: 3)
        }
        check(capped.count == 3, "L13 clipboard capped at limit (got \(capped.count))")
        check(capped[0].text == "item9", "L13 cap keeps newest (got \(capped.map(\.text)))")
        let f0 = ShelfFile(url: URL(fileURLWithPath: "/tmp/a.txt"), createdAt: t0)
        let f1 = ShelfFile(
            url: URL(fileURLWithPath: "/tmp/b.txt"), createdAt: t0.addingTimeInterval(1))
        let shelf1 = ShelfFiles.adding([f0, f1], to: [], limit: 5)
        check(shelf1.count == 2 && shelf1[0].url == f1.url, "L13 files newest first")
        let shelfDup = ShelfFiles.adding([f0], to: shelf1, limit: 5)
        check(shelfDup.count == 2 && shelfDup[0].url == f0.url, "L13 re-drop dedupes to front")
        let shelfRemoved = ShelfFiles.removing(f0.url, from: shelfDup)
        check(shelfRemoved.count == 1 && shelfRemoved[0].url == f1.url, "L13 file removed")
        var filesCapped = [ShelfFile]()
        for i in 0..<8 {
            filesCapped = ShelfFiles.adding(
                [
                    ShelfFile(
                        url: URL(fileURLWithPath: "/tmp/f\(i)"),
                        createdAt: t0.addingTimeInterval(Double(i)))
                ],
                to: filesCapped, limit: 4)
        }
        check(filesCapped.count == 4, "L13 files capped (got \(filesCapped.count))")

        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let origShow = cfg.showShelfTab
            let origLimit = cfg.shelfLimit
            check(cfg.showShelfTab, "L13 shelf tab default on")
            check(cfg.clampedShelfLimit == 20, "L13 default shelf limit 20")
            cfg.showShelfTab = false
            check(defaults.bool(forKey: "showShelfTab") == false, "L13 shelf tab persisted")
            cfg.shelfLimit = 500
            check(cfg.clampedShelfLimit == 50, "L13 shelf limit clamps at 50")
            cfg.shelfLimit = 0
            check(cfg.clampedShelfLimit == 1, "L13 shelf limit clamps at 1")
            cfg.shelfLimit = 12
            check(defaults.integer(forKey: "shelfLimit") == 12, "L13 shelf limit persisted")
            cfg.showShelfTab = origShow
            cfg.shelfLimit = origLimit
            defaults.removeObject(forKey: "showShelfTab")
            defaults.removeObject(forKey: "shelfLimit")
        }

        // L12. Multi-monitor: screen selection (mouse/notch preference) and
        // floating-pill geometry, plus config persistence.
        let notchMain = IslandMetrics.ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true,
            containsMouse: true)
        let extNoNotch = IslandMetrics.ScreenInfo(
            frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), hasNotch: false,
            containsMouse: false)
        let mouseNoNotch = IslandMetrics.ScreenInfo(
            frame: CGRect(x: 4072, y: 0, width: 1920, height: 1080), hasNotch: false,
            containsMouse: true)
        check(
            IslandMetrics.islandScreen(screens: [notchMain, extNoNotch], preferMouseScreen: true)
                == notchMain,
            "L12 mouse notch screen preferred")
        check(
            IslandMetrics.islandScreen(
                screens: [extNoNotch, mouseNoNotch], preferMouseScreen: true) == mouseNoNotch,
            "L12 no notch screens: mouse wins")
        check(
            IslandMetrics.islandScreen(screens: [mouseNoNotch], preferMouseScreen: true)
                == mouseNoNotch,
            "L12 mouse screen fallback (floating)")
        check(
            IslandMetrics.islandScreen(
                screens: [extNoNotch, mouseNoNotch], preferMouseScreen: false) == mouseNoNotch,
            "L12 no-follow falls back to mouse without notch")
        check(
            IslandMetrics.islandScreen(screens: [mouseNoNotch], preferMouseScreen: false)
                == mouseNoNotch,
            "L12 no-follow falls back to mouse")
        check(
            IslandMetrics.islandScreen(screens: [], preferMouseScreen: true) == nil,
            "L12 empty screens nil")
        check(
            IslandMetrics.floatingTopInset(menuBarHeight: 24) == 30,
            "L12 floating inset below menu bar")
        let pill = IslandMetrics.floatingPillFrame(
            screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            size: CGSize(width: 456, height: 560), menuBarHeight: 24)
        check(
            abs(pill.midX - 1280) < 0.01,
            "L12 floating pill centered horizontally (got \(pill.midX))")
        check(
            abs(pill.maxY - (1440 - 30)) < 0.01,
            "L12 floating pill sits below menu bar (got \(pill.maxY))")

        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let origFollow = cfg.followMouseScreen
            let origFloat = cfg.floatingPillOnNoNotch
            check(cfg.followMouseScreen, "L12 follow mouse default on")
            check(cfg.floatingPillOnNoNotch, "L12 floating pill default on")
            cfg.followMouseScreen = false
            check(defaults.bool(forKey: "followMouseScreen") == false, "L12 follow persisted")
            cfg.floatingPillOnNoNotch = false
            check(defaults.bool(forKey: "floatingPillOnNoNotch") == false, "L12 float persisted")
            cfg.followMouseScreen = origFollow
            cfg.floatingPillOnNoNotch = origFloat
            defaults.removeObject(forKey: "followMouseScreen")
            defaults.removeObject(forKey: "floatingPillOnNoNotch")
        }

        // L14. Approval heartbeat: phantom-prompt protection — pinned
        // prompts verify live agent state every poll and self-clear when the
        // agent moved on; missing data never phantom-clears.
        check(
            IslandMetrics.ApprovalHeartbeat.shouldKeepPinned(
                kind: .accessRequest, liveStatus: "blocked"),
            "L14 blocked keeps prompt pinned")
        check(
            IslandMetrics.ApprovalHeartbeat.shouldKeepPinned(
                kind: .waiting, liveStatus: nil),
            "L14 unknown status keeps pinned (no phantom clear)")
        check(
            !IslandMetrics.ApprovalHeartbeat.shouldKeepPinned(
                kind: .accessRequest, liveStatus: "working"),
            "L14 working clears phantom prompt")
        check(
            !IslandMetrics.ApprovalHeartbeat.shouldKeepPinned(
                kind: .accessRequest, liveStatus: "done"),
            "L14 done clears phantom prompt")
        check(
            !IslandMetrics.ApprovalHeartbeat.shouldKeepPinned(
                kind: .accessRequest, liveStatus: "idle"),
            "L14 idle clears phantom prompt")
        check(
            !IslandMetrics.ApprovalHeartbeat.shouldKeepPinned(
                kind: .accessRequest, liveStatus: "failed"),
            "L14 failed clears phantom prompt")
        check(
            !IslandMetrics.ApprovalHeartbeat.shouldKeepPinned(
                kind: .progress, liveStatus: "blocked"),
            "L14 non-approval kinds never pin")
        let kept = IslandMetrics.ApprovalHeartbeat.verifyPendingKeys(
            ["1-1", "1-2", "1-3"],
            liveStatuses: ["1-1": "blocked", "1-2": "working", "1-4": "done"])
        check(
            kept == ["1-1", "1-3"],
            "L14 verify prunes moved-on panes, keeps unknown (got \(kept))")

        // L14. Manager heartbeat: pending map + current event self-clear.
        MainActor.assumeIsolated {
            let manager = AgentEventManager(
                eventsFileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("lc-l14-\(UUID().uuidString).jsonl"),
                capture: false)
            manager.pendingApprovals["1-1"] = (variance: .yesNo, choices: nil)
            manager.pendingApprovals["1-2"] = (variance: .multi, choices: ["a", "b"])
            manager.heartbeatVerify(liveStatuses: ["1-1": "blocked", "1-2": "done"])
            check(
                manager.pendingApprovals["1-1"] != nil && manager.pendingApprovals["1-2"] == nil,
                "L14 manager prunes only moved-on panes")
            let prompt = AgentEvent(
                source: "kilo", kind: .accessRequest, title: "run tests?",
                message: nil, paneId: "2-1", workspaceId: nil,
                variance: .yesNo, choices: nil, playSound: true, persistent: true)
            manager.publishEventForTesting(prompt)
            manager.heartbeatVerify(liveStatuses: ["2-1": "blocked"])
            check(
                manager.currentEventForTesting?.paneId == "2-1",
                "L14 still-blocked prompt survives heartbeat")
            manager.heartbeatVerify(liveStatuses: ["2-1": "working"])
            check(
                manager.currentEventForTesting == nil,
                "L14 moved-on prompt self-clears (phantom kill)")
        }

        // L15. Full-screen & space policy: pure visibility policy and
        // transition settle delay, plus config persistence.
        check(
            IslandMetrics.FullScreenPolicy.shouldShow(
                inFullScreen: false, showInFullScreen: true),
            "L15 normal desktop shows island")
        check(
            IslandMetrics.FullScreenPolicy.shouldShow(
                inFullScreen: true, showInFullScreen: true),
            "L15 full screen with override shows island")
        check(
            !IslandMetrics.FullScreenPolicy.shouldShow(
                inFullScreen: true, showInFullScreen: false),
            "L15 full screen without override hides island")
        check(
            IslandMetrics.FullScreenPolicy.transitionSettleDelay > 0,
            "L15 settle delay positive")
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let orig = cfg.showInFullScreen
            check(cfg.showInFullScreen, "L15 full-screen default on")
            cfg.showInFullScreen = false
            check(
                defaults.bool(forKey: "showInFullScreen") == false,
                "L15 full-screen toggle persisted")
            cfg.showInFullScreen = orig
            defaults.removeObject(forKey: "showInFullScreen")
        }

        // L16. Menu-bar collision avoidance: clearance geometry, collision
        // detection, config persistence.
        let clear = IslandMetrics.MenuBarClearance.maxIdleWidth(
            side: .right, notchWidth: 200, screenWidth: 1512,
            auxLeft: 300, auxRight: 400)
        check(abs(clear - 400) < 0.01, "L16 right clearance uses aux right (got \(clear))")
        let clearLeft = IslandMetrics.MenuBarClearance.maxIdleWidth(
            side: .left, notchWidth: 200, screenWidth: 1512,
            auxLeft: 300, auxRight: 400)
        check(abs(clearLeft - 300) < 0.01, "L16 left clearance uses aux left")
        let clearFallback = IslandMetrics.MenuBarClearance.maxIdleWidth(
            side: .right, notchWidth: 200, screenWidth: 1512, auxLeft: 0, auxRight: 0)
        check(
            abs(clearFallback - (1512 - 200)) < 0.01,
            "L16 fallback clearance = screen minus notch (got \(clearFallback))")
        let clearCenter = IslandMetrics.MenuBarClearance.maxIdleWidth(
            side: .center, notchWidth: 200, screenWidth: 1512, auxLeft: 300, auxRight: 400)
        check(abs(clearCenter - 1312) < 0.01, "L16 center clearance spans both sides")
        check(
            IslandMetrics.MenuBarClearance.collides(
                side: .right, stripWidth: 500, notchWidth: 200, screenWidth: 1512,
                auxLeft: 300, auxRight: 400),
            "L16 wide strip collides with icons")
        check(
            !IslandMetrics.MenuBarClearance.collides(
                side: .right, stripWidth: 300, notchWidth: 200, screenWidth: 1512,
                auxLeft: 300, auxRight: 400),
            "L16 narrow strip clears icons")
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let orig = cfg.avoidMenuBarIcons
            check(cfg.avoidMenuBarIcons, "L16 avoid-icons default on")
            cfg.avoidMenuBarIcons = false
            check(
                defaults.bool(forKey: "avoidMenuBarIcons") == false,
                "L16 avoid-icons persisted")
            cfg.avoidMenuBarIcons = orig
            defaults.removeObject(forKey: "avoidMenuBarIcons")
        }

        // L17. Display hot-swap & ghost validation: window-frame checks
        // against current screens.
        let screenA = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let screenB = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let onA = CGRect(x: 600, y: 500, width: 504, height: 560)
        let ghost = CGRect(x: 5000, y: 500, width: 504, height: 560)
        check(
            IslandMetrics.DisplayAnchor.frameIsOnScreens(frame: onA, screens: [screenA, screenB]),
            "L17 frame on live screen is valid")
        check(
            !IslandMetrics.DisplayAnchor.frameIsOnScreens(frame: ghost, screens: [screenA]),
            "L17 disconnected-display frame is ghost")
        let onB = CGRect(x: 3000, y: 500, width: 504, height: 560)
        check(
            IslandMetrics.DisplayAnchor.frameIsOnScreens(frame: onB, screens: [screenA, screenB]),
            "L17 frame lands on the other live screen")
        check(
            IslandMetrics.DisplayAnchor.needsReanchor(
                isVisible: true, windowFrame: ghost, screens: [screenA]),
            "L17 visible ghost needs re-anchor")
        check(
            !IslandMetrics.DisplayAnchor.needsReanchor(
                isVisible: false, windowFrame: ghost, screens: [screenA]),
            "L17 hidden ghost needs no re-anchor")
        check(
            !IslandMetrics.DisplayAnchor.needsReanchor(
                isVisible: true, windowFrame: onA, screens: [screenA]),
            "L17 on-screen window needs no re-anchor")

        // L18. Terminal-agnostic focus: bundle-ID registry resolution and
        // config persistence.
        check(
            TerminalRegistry.runningTerminal(
                runningBundleIDs: ["com.googlecode.iterm2"]) == "com.googlecode.iterm2",
            "L18 iTerm2 detected")
        check(
            TerminalRegistry.runningTerminal(
                runningBundleIDs: ["dev.warp.Warp-Stable", "com.apple.Terminal"])
                == "dev.warp.Warp-Stable",
            "L18 Warp preferred over Terminal by registry order")
        check(
            TerminalRegistry.runningTerminal(
                runningBundleIDs: ["com.apple.Terminal"]) == "com.apple.Terminal",
            "L18 Terminal fallback")
        check(
            TerminalRegistry.runningTerminal(runningBundleIDs: ["com.foo.Bar"]) == nil,
            "L18 unknown apps ignored")
        check(
            TerminalRegistry.runningTerminal(
                runningBundleIDs: ["io.alacritty", "com.googlecode.iterm2"],
                preferred: "com.googlecode.iterm2") == "com.googlecode.iterm2",
            "L18 explicit preference wins")
        check(
            TerminalRegistry.runningTerminal(
                runningBundleIDs: ["io.alacritty"], preferred: "com.googlecode.iterm2")
                == "io.alacritty",
            "L18 unavailable preference falls back to running terminal")
        check(
            TerminalRegistry.preferredBundleIDs.contains("com.ghostty.app"),
            "L18 Ghostty in registry")
        check(
            TerminalRegistry.preferredBundleIDs.contains("org.wezfurlong.wezterm"),
            "L18 WezTerm in registry")
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let orig = cfg.preferredTerminalBundleID
            check(cfg.preferredTerminalBundleID == nil, "L18 no terminal preference by default")
            cfg.preferredTerminalBundleID = "com.ghostty.app"
            check(
                defaults.string(forKey: "preferredTerminalBundleID") == "com.ghostty.app",
                "L18 terminal preference persisted")
            cfg.preferredTerminalBundleID = orig
            defaults.removeObject(forKey: "preferredTerminalBundleID")
        }

        // L19. Herdr direct socket protocol: NDJSON framing, request lines,
        // response/error parsing, socket path resolution.
        let sockRequest = HerdrSocketProtocol.requestLine(
            id: "req_1", method: "agent.list")
        check(
            sockRequest == #"{"id":"req_1","method":"agent.list","params":{}}"#,
            "L19 request line shape (got \(sockRequest))")
        let requestParams = HerdrSocketProtocol.requestLine(
            id: "req_2", method: "pane.send_keys",
            paramsJSON: #"{"pane_id":"w1:p1","keys":["y","enter"]}"#)
        check(
            requestParams.contains("pane.send_keys") && requestParams.contains("w1:p1"),
            "L19 params embedded in request")
        let okLine = #"{"id":"req_1","result":{"type":"pong"}}"#
        guard let ok = HerdrSocketProtocol.parseResponseLine(okLine) else {
            check(false, "L19 success response parses")
            fatalError()
        }
        check(ok.id == "req_1" && !ok.isError, "L19 success id + no error")
        check(
            ok.result?.contains("pong") == true,
            "L19 result JSON preserved (got \(String(describing: ok.result)))")
        let errLine = #"{"id":"req_9","error":{"code":"not_found","message":"pane not found"}}"#
        guard let err = HerdrSocketProtocol.parseResponseLine(errLine) else {
            check(false, "L19 error response parses")
            fatalError()
        }
        check(err.isError && err.errorCode == "not_found", "L19 error code parsed")
        check(
            err.errorMessage == "pane not found",
            "L19 error message parsed (got \(String(describing: err.errorMessage)))")
        check(
            HerdrSocketProtocol.parseResponseLine("not json") == nil,
            "L19 garbage line ignored")
        check(
            HerdrSocketProtocol.parseResponseLine(#"{"result":{"type":"pong"}}"#) == nil,
            "L19 missing id ignored")
        let lines = HerdrSocketProtocol.extractLines(
            from: Data("\(okLine)\n\(errLine)\n".utf8))
        check(lines.count == 2, "L19 NDJSON split into lines (got \(lines.count))")
        check(
            HerdrSocketProtocol.socketPath(
                env: ["HERDR_SOCKET_PATH": "/tmp/custom.sock"], home: "/Users/x")
                == "/tmp/custom.sock",
            "L19 env socket path wins")
        check(
            HerdrSocketProtocol.socketPath(env: [:], home: "/Users/x")
                == "/Users/x/.config/herdr/herdr.sock",
            "L19 default socket path")

        // L20. Claude Code hook installer: settings merge (preserves existing
        // keys/hooks), hook command, payload mapping.
        let command = ClaudeHookInstaller.hookCommand(port: 41817)
        check(
            command.contains("127.0.0.1:41817/events") && command.contains("curl"),
            "L20 hook command posts to ingest (got \(command))")
        let merged = ClaudeHookInstaller.mergedSettings(
            existing: ["model": "opus", "hooks": ["PreToolUse": [["matcher": ""]]]],
            port: 41817)
        check(merged["model"] as? String == "opus", "L20 unrelated settings preserved")
        let hooks = merged["hooks"] as? [String: Any]
        check(
            hooks?["PreToolUse"] != nil && hooks?["PermissionPrompt"] != nil
                && hooks?["Stop"] != nil,
            "L20 existing hooks preserved + bantay hooks added")
        let permission = ClaudeHookInstaller.mapToEventPayload([
            "hook_event_name": "PermissionPrompt",
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf build"],
            "permission_prompt_mode": "default",
        ])
        check(
            permission?["type"] as? String == "access_request",
            "L20 PermissionPrompt maps to access_request")
        check(
            permission?["title"] as? String == "rm -rf build",
            "L20 tool_input command becomes title")
        check(
            permission?["variance"] as? String == "yes-no",
            "L20 prompt defaults to yes-no")
        // Round-trip: the mapped payload must decode through AgentEventPayload
        // (the same decoder the events file / ingest use). A producer that
        // emits a raw value the enum rejects drops the whole event silently —
        // this pins the producer↔decoder contract so it can't regress.
        if let permission {
            let data = try? JSONSerialization.data(withJSONObject: permission)
            let decoded = data.flatMap {
                try? JSONDecoder().decode(AgentEventPayload.self, from: $0)
            }
            check(
                decoded?.type == .accessRequest && decoded?.variance == .yesNo,
                "L20 mapped payload round-trips through AgentEventPayload")
        }
        let stop = ClaudeHookInstaller.mapToEventPayload([
            "hook_event_name": "Stop",
            "tool_name": "Bash",
        ])
        check(
            stop?["type"] as? String == "completed",
            "L20 Stop maps to completed")
        check(
            ClaudeHookInstaller.mapToEventPayload(["hook_event_name": "SubagentStart"]) == nil,
            "L20 unhandled events ignored")

        // L21. Visibility policy: island shows when enabled/not snoozed and
        // (hasWork || showWhenIdle || forced); hideAtStartup only gates until
        // first show; config persistence.
        let v: (Bool, Bool, Bool, Bool, Bool, Bool, Bool) -> Bool = {
            IslandMetrics.VisibilityPolicy.shouldShow(
                islandEnabled: $0, snoozed: $1, hideAtStartup: $2, didShowOnce: $3,
                hasWork: $4, showWhenIdle: $5, forced: $6)
        }
        check(
            v(true, false, false, true, true, false, false),
            "L21 work shows island")
        check(
            v(true, false, true, false, false, true, false),
            "L21 showWhenIdle shows island at launch despite hideAtStartup")
        check(
            v(true, false, true, false, false, false, true),
            "L21 forced shows island despite hideAtStartup")
        check(
            v(true, false, true, true, true, false, false),
            "L21 hideAtStartup un-gates after first show")
        check(
            !v(false, false, false, true, true, false, false),
            "L21 disabled island never shows")
        check(
            !v(true, true, false, true, true, false, false),
            "L21 snoozed island never shows")
        check(
            !v(true, false, true, false, false, false, false),
            "L21 hideAtStartup + no work + not idle-show hides")
        check(
            v(true, false, false, true, false, false, true),
            "L21 forced shows even without work")
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let orig = cfg.showIslandWhenIdle
            check(cfg.showIslandWhenIdle, "L21 idle-show default on")
            cfg.showIslandWhenIdle = false
            check(
                defaults.bool(forKey: "showIslandWhenIdle") == false,
                "L21 idle-show persisted")
            cfg.showIslandWhenIdle = orig
            defaults.removeObject(forKey: "showIslandWhenIdle")
        }

        // L22. Queue-card display cap: many-choice prompts collapse to
        // maxDisplayedOptions buttons + `+N` overflow (keyboard 1-9 still
        // covers all options), so cards never overflow the panel width.
        let tenChoices = IslandMetrics.ApprovalControls.make(
            variance: .multi, choices: Array(repeating: "x", count: 10))
        check(
            tenChoices.displayedLabels().count
                == IslandMetrics.ApprovalControls.maxDisplayedOptions,
            "L22 ten choices collapse to \(IslandMetrics.ApprovalControls.maxDisplayedOptions) buttons"
        )
        check(
            tenChoices.overflowCount() == 4,
            "L22 overflow shows +4 (got \(tenChoices.overflowCount()))")
        let three = IslandMetrics.ApprovalControls.make(
            variance: .choices, choices: ["a", "b", "c"])
        check(
            three.displayedLabels().count == 3 && three.overflowCount() == 0,
            "L22 under-cap shows all")
        let exact = IslandMetrics.ApprovalControls.make(
            variance: .choices, choices: Array(repeating: "x", count: 6))
        check(exact.overflowCount() == 0, "L22 exactly-cap has no overflow")
        check(
            IslandMetrics.ApprovalControls.maxDisplayedOptions >= 4
                && IslandMetrics.ApprovalControls.maxDisplayedOptions <= 8,
            "L22 cap stays in sane range")
        let small = IslandMetrics.ApprovalControls.make(
            variance: .multi, choices: Array(repeating: "x", count: 10))
        check(
            small.displayedLabels(cap: 2).count == 2 && small.overflowCount(cap: 2) == 8,
            "L22 custom cap respected")

        // L23. Centered idle split + fit-aware chips.
        check(
            IslandMetrics.effectiveTopOffset(
                side: .center, isExpanded: false, topInset: 47) == 0,
            "L23 centered idle sits in the notch row")
        check(
            IslandMetrics.effectiveTopOffset(
                side: .center, isExpanded: true, topInset: 47) == 47,
            "L23 centered expanded still drops under the menu bar")
        let side = IslandMetrics.centeredSideWidth(windowWidth: 504, notchWidth: 200)
        check(abs(side - 142) < 0.01, "L23 centered side width (got \(side))")
        check(
            IslandMetrics.centeredSideWidth(windowWidth: 200, notchWidth: 200) == 0,
            "L23 no room for sides when window == notch")
        let fit1 = IslandMetrics.idleFitChips(
            agentCount: 3, maxChips: 3, nameLengths: [4, 4, 4], availableWidth: 200)
        check(fit1 == 3, "L23 wide clearance fits all three (got \(fit1))")
        let fit2 = IslandMetrics.idleFitChips(
            agentCount: 3, maxChips: 3, nameLengths: [4, 4, 4], availableWidth: 90)
        check(fit2 >= 1 && fit2 < 3, "L23 tight clearance truncates (got \(fit2))")
        let fit3 = IslandMetrics.idleFitChips(
            agentCount: 3, maxChips: 2, nameLengths: [4, 4, 4], availableWidth: 500)
        check(fit3 == 2, "L23 fit never exceeds maxChips (got \(fit3))")
        check(
            IslandMetrics.idleFitChips(
                agentCount: 0, maxChips: 3, nameLengths: [], availableWidth: 200) == 0,
            "L23 empty roster fits nothing")
        let fit4 = IslandMetrics.idleFitChips(
            agentCount: 3, maxChips: 3, nameLengths: [30, 30, 30], availableWidth: 200)
        check(fit4 >= 1 && fit4 <= 3, "L23 long names shrink fit (got \(fit4))")
        check(fit4 <= fit1, "L23 longer names never fit more than short ones")

        // L24. Expanded height accounts for the shelf tab bar, divider, and
        // +N overflow rows — otherwise the bottom roster rows clip.
        let baseSize = IslandMetrics.expandedSize(topInset: 47, agentCount: 3)
        let withTab = IslandMetrics.expandedSize(
            topInset: 47, agentCount: 3, queueCount: 0, shelfTabVisible: true)
        check(
            abs(
                withTab.height - baseSize.height
                    - (IslandMetrics.shelfTabBarHeight + IslandMetrics.dividerHeight)) < 0.01,
            "L24 shelf tab adds tab+divider height (got \(withTab.height) vs \(baseSize.height))")
        let withOverflow = IslandMetrics.expandedSize(
            topInset: 47, agentCount: 3, queueCount: 0, overflowCount: 2)
        check(
            abs(
                withOverflow.height - baseSize.height - 2 * IslandMetrics.overflowRowHeight)
                < 0.01,
            "L24 overflow rows add height (got \(withOverflow.height) vs \(baseSize.height))")
        let both = IslandMetrics.expandedSize(
            topInset: 47, agentCount: 3, queueCount: 0, shelfTabVisible: true,
            overflowCount: 1)
        let expected =
            baseSize.height + IslandMetrics.shelfTabBarHeight + IslandMetrics.dividerHeight
            + IslandMetrics.overflowRowHeight
        check(abs(both.height - expected) < 0.01, "L24 tab + overflow stack correctly")
        check(
            IslandMetrics.contentHeight(
                isExpanded: true, topInset: 47, agentCount: 3,
                shelfTabVisible: true) == withTab.height - 47,
            "L24 content height excludes top inset with tab chrome")
        check(
            IslandMetrics.expandedSize(topInset: 47, agentCount: 3).height
                <= IslandMetrics.maxExpandedHeight,
            "L24 cap still applies")
        check(
            IslandMetrics.shelfTabBarHeight > 0 && IslandMetrics.dividerHeight > 0
                && IslandMetrics.overflowRowHeight > 0,
            "L24 chrome constants positive")

        // L25. Per-source mute filters the published roster and persists;
        // the roster scroll area is capped so chrome stays visible.
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let orig = cfg.mutedSources
            cfg.mutedSources = ["codex"]
            check(
                defaults.stringArray(forKey: "mutedSources") == ["codex"],
                "L25 muted source persisted")
            let manager = AgentEventManager(
                eventsFileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("lc-l25-\(UUID().uuidString).jsonl"),
                capture: false)
            let kilo = AgentSnapshot(
                id: "p1", source: "kilo", kind: .progress, title: nil, message: nil,
                paneId: "1-1", workspaceId: nil, cwd: nil, variance: nil, choices: nil,
                startedAt: nil,
                projectContext: nil)
            let codex = AgentSnapshot(
                id: "p2", source: "codex", kind: .progress, title: nil, message: nil,
                paneId: "1-2", workspaceId: nil, cwd: nil, variance: nil, choices: nil,
                startedAt: nil,
                projectContext: nil)
            let visible = manager.mergeApprovals(into: [kilo, codex])
            check(
                visible.map(\.source) == ["kilo"],
                "L25 muted source filtered from roster (got \(visible.map(\.source)))")
            cfg.mutedSources = []
            let all = manager.mergeApprovals(into: [kilo, codex])
            check(all.count == 2, "L25 unmuted roster restored")
            cfg.mutedSources = orig
            defaults.removeObject(forKey: "mutedSources")
        }

        // L26. herdr binary discovery covers every install location:
        // HERDR_INSTALL_DIR, PATH, ~/.local/bin (official installer), both
        // Homebrew prefixes, and ~/.herdr/bin, deduped in priority order.
        let envNoHerdr = [
            "PATH": "/usr/bin:/bin"
        ]
        let pathsNoOverride = HerdrSocketAdapter.candidateHerdrPaths(
            env: envNoHerdr, home: "/Users/someone")
        check(
            pathsNoOverride == [
                "/usr/bin/herdr", "/bin/herdr", "/Users/someone/.local/bin/herdr",
                "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr",
                "/Users/someone/.herdr/bin/herdr",
            ],
            "L26 fallback chain in priority order (got \(pathsNoOverride))")
        let withOverride = HerdrSocketAdapter.candidateHerdrPaths(
            env: ["HERDR_INSTALL_DIR": "/custom/bin"], home: "/Users/someone")
        check(
            withOverride.first == "/custom/bin/herdr",
            "L26 HERDR_INSTALL_DIR wins (got \(String(describing: withOverride.first)))")
        let deduped = HerdrSocketAdapter.candidateHerdrPaths(
            env: ["PATH": "/opt/homebrew/bin:/usr/local/bin"], home: "/Users/someone")
        check(
            deduped.filter { $0 == "/opt/homebrew/bin/herdr" }.count == 1,
            "L26 PATH candidates dedupe against fallbacks")
        let customName = HerdrSocketAdapter.candidateHerdrPaths(
            env: [:], home: "/Users/someone", binName: "herdr-bin")
        check(
            customName.first == "/Users/someone/.local/bin/herdr-bin",
            "L26 custom binary name honored")

        // L27. pane list tries --format json first (herdr < 0.8), then the
        // plain JSON-only form (herdr 0.8+).
        let variants = HerdrSocketAdapter.paneListCommandVariants()
        check(
            variants.count == 2 && variants[0] == ["pane", "list", "--format", "json"]
                && variants[1] == ["pane", "list"],
            "L27 pane list variants: flag first, plain fallback (got \(variants))")

        // L28. Disabling the Claude hook removes only Bantay's entries; hooks
        // installed by other tools (herdr integration) survive.
        let settingsWithHooks: [String: Any] = [
            "apiKeyHelper": "default",
            "hooks": [
                "PermissionPrompt": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": "herdr-claude-integration"]
                        ],
                    ],
                    [
                        "matcher": "bantay",
                        "hooks": [
                            [
                                "type": "command",
                                "command":
                                    "curl -s -X POST --data-binary @- http://127.0.0.1:41817/events",
                            ]
                        ],
                    ],
                ],
                "Stop": [
                    [
                        "matcher": "",
                        "hooks": [
                            [
                                "type": "command",
                                "command":
                                    "curl -s -X POST --data-binary @- http://127.0.0.1:41817/events",
                            ]
                        ],
                    ]
                ],
                "PostToolUse": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": "some-other-tool"]
                        ],
                    ]
                ],
            ],
        ]
        let stripped = ClaudeHookInstaller.removingBantayHooks(from: settingsWithHooks)
        let strippedHooks = stripped["hooks"] as? [String: Any]
        check(
            stripped["apiKeyHelper"] as? String == "default",
            "L28 unrelated settings preserved")
        check(
            (strippedHooks?["PermissionPrompt"] as? [[String: Any]])?.count == 1,
            "L28 herdr PermissionPrompt entry survives")
        check(
            strippedHooks?["Stop"] == nil,
            "L28 bantay-only Stop entry removed")
        check(
            (strippedHooks?["PostToolUse"] as? [[String: Any]])?.count == 1,
            "L28 unrelated event hooks untouched")
        let allBantay: [String: Any] = [
            "hooks": [
                "Stop": [
                    [
                        "matcher": "",
                        "hooks": [
                            [
                                "type": "command",
                                "command":
                                    "curl -s -X POST --data-binary @- http://127.0.0.1:41817/events",
                            ]
                        ],
                    ]
                ]
            ]
        ]
        let emptyHooks = ClaudeHookInstaller.removingBantayHooks(from: allBantay)
        check(
            emptyHooks["hooks"] == nil,
            "L28 empty hooks key removed entirely")
        let noHooks: [String: Any] = ["apiKeyHelper": "default"]
        check(
            (ClaudeHookInstaller.removingBantayHooks(from: noHooks)["hooks"]) == nil,
            "L28 settings without hooks unchanged")

        // L28b. Hook merge appends instead of overwriting, and removal filters
        // per hook, so foreign hooks sharing an entry survive (kilo review on
        // PR 16).
        let foreignPermission: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": "foreign-tool"]],
        ]
        let withForeign = ClaudeHookInstaller.mergedSettings(
            existing: ["hooks": ["PermissionPrompt": [foreignPermission]]], port: 41817)
        let mergedPermission =
            (withForeign["hooks"] as? [String: Any])?["PermissionPrompt"]
            as? [[String: Any]]
        check(
            mergedPermission?.count == 2,
            "L28b foreign + bantay entries coexist after merge")
        let remerged = ClaudeHookInstaller.mergedSettings(existing: withForeign, port: 41817)
        let rePermission =
            (remerged["hooks"] as? [String: Any])?["PermissionPrompt"]
            as? [[String: Any]]
        check(
            rePermission?.count == 2,
            "L28b re-merge does not duplicate bantay entries")
        let bantayCommand = ClaudeHookInstaller.hookCommand(port: 41817)
        let sharedEntry: [String: Any] = [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": bantayCommand],
                ["type": "command", "command": "foreign-tool"],
            ],
        ]
        let strippedShared = ClaudeHookInstaller.removingBantayHooks(
            from: ["hooks": ["Stop": [sharedEntry]]])
        let stopShared =
            (strippedShared["hooks"] as? [String: Any])?["Stop"]
            as? [[String: Any]]
        check(
            stopShared?.count == 1,
            "L28b shared entry keeps foreign hook")
        check(
            (stopShared?.first?["hooks"] as? [[String: Any]])?.count == 1,
            "L28b only the bantay hook removed from shared entry")

        // L28c. LaunchAgent install surfaces plist write failures and verifies
        // the agent loaded (kilo review on PR 16).
        let savedPlistPath = LaunchAgent.plistPath
        let savedRunner = LaunchAgent.processRunner
        LaunchAgent.processRunner = { _ in 0 }
        LaunchAgent.plistPath = "/dev/null/bantay-impossible.plist"
        check(
            !LaunchAgent.install(binaryPath: "/bin/echo"),
            "L28c install returns false when plist write fails")
        let tmpPlist = NSTemporaryDirectory() + "bantay-logiccheck-\(UUID().uuidString).plist"
        LaunchAgent.plistPath = tmpPlist
        check(
            LaunchAgent.install(binaryPath: "/bin/echo"),
            "L28c install reports loaded when plist written + launchctl ok")
        try? FileManager.default.removeItem(atPath: tmpPlist)
        LaunchAgent.plistPath = savedPlistPath
        LaunchAgent.processRunner = savedRunner

        // L29. Agent classification covers the herdr 0.8 agent families; new
        // families have no known transcript root but classify safely.
        check(
            AgentDetector.canonicalName(forProcess: "grok") == "grok"
                && AgentDetector.canonicalName(forProcess: "agy") == "antigravity"
                && AgentDetector.canonicalName(forProcess: "pi") == "pi"
                && AgentDetector.canonicalName(forProcess: "copilot") == "copilot"
                && AgentDetector.canonicalName(forProcess: "qoder-cli") == "qoder"
                && AgentDetector.canonicalName(forProcess: "kimi") == "kimi"
                && AgentDetector.canonicalName(forProcess: "hermes") == "hermes",
            "L29 new agent families classified")
        check(
            AgentDetector.transcriptSearchPaths(home: "/Users/someone", name: "grok").isEmpty
                && AgentDetector.transcriptSearchPaths(home: "/Users/someone", name: "pi").isEmpty,
            "L29 unknown transcript roots are empty (no crash)")
        let detectedGrok = StandaloneAgentScanner.detect(
            samples: [
                ProcessSample(
                    pid: 42, name: "grok", command: "grok -p task", environmentLines: [])
            ],
            home: "/Users/someone")
        check(
            detectedGrok.first?.name == "grok" && detectedGrok.first?.activity == nil,
            "L29 grok detected standalone with no transcript")

        // L30. Muting fully suppresses a source: its events never become the
        // pill (no sound, no approval attention); unmuting restores them.
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let orig = cfg.mutedSources
            let manager = AgentEventManager(
                eventsFileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("lc-l30-\(UUID().uuidString).jsonl"),
                capture: false)
            let prompt = AgentEvent(
                source: "codex", kind: .accessRequest, title: "run tests?",
                message: nil, paneId: "3-1", workspaceId: nil,
                variance: .yesNo, choices: nil, playSound: true, persistent: true)
            cfg.mutedSources = ["codex"]
            manager.publishEventForTesting(prompt)
            check(
                manager.currentEventForTesting == nil,
                "L30 muted source never becomes the pill")
            cfg.mutedSources = []
            manager.publishEventForTesting(prompt)
            check(
                manager.currentEventForTesting?.source == "codex",
                "L30 unmuted source surfaces again")
            cfg.mutedSources = orig
            defaults.removeObject(forKey: "mutedSources")
        }

        // L31. Quiet hours: window math with overnight wrap and exact
        // boundaries; config persistence. Effect is sound suppression only —
        // approvals stay visible, so nothing can be silently missed.
        check(
            IslandMetrics.quietHoursActive(
                nowMinutes: 10 * 60, startMinutes: 9 * 60, endMinutes: 17 * 60),
            "L31 active mid-window")
        check(
            !IslandMetrics.quietHoursActive(
                nowMinutes: 8 * 60 + 59, startMinutes: 9 * 60, endMinutes: 17 * 60),
            "L31 inactive before start")
        check(
            !IslandMetrics.quietHoursActive(
                nowMinutes: 17 * 60, startMinutes: 9 * 60, endMinutes: 17 * 60),
            "L31 inactive at end boundary")
        check(
            IslandMetrics.quietHoursActive(
                nowMinutes: 9 * 60, startMinutes: 9 * 60, endMinutes: 17 * 60),
            "L31 active at start boundary")
        check(
            IslandMetrics.quietHoursActive(
                nowMinutes: 23 * 60, startMinutes: 22 * 60, endMinutes: 6 * 60),
            "L31 overnight active past midnight")
        check(
            IslandMetrics.quietHoursActive(
                nowMinutes: 5 * 60 + 59, startMinutes: 22 * 60, endMinutes: 6 * 60),
            "L31 overnight active before end")
        check(
            !IslandMetrics.quietHoursActive(
                nowMinutes: 12 * 60, startMinutes: 22 * 60, endMinutes: 6 * 60),
            "L31 overnight inactive midday")
        check(
            !IslandMetrics.quietHoursActive(
                nowMinutes: 6 * 60, startMinutes: 22 * 60, endMinutes: 6 * 60),
            "L31 overnight inactive at end")
        check(
            !IslandMetrics.quietHoursActive(
                nowMinutes: 10 * 60, startMinutes: 10 * 60, endMinutes: 10 * 60),
            "L31 zero-length window inactive")
        check(
            IslandMetrics.quietHoursActive(
                nowMinutes: 0, startMinutes: 0, endMinutes: 24 * 60),
            "L31 full-day window active")
        check(
            IslandMetrics.quietHoursActive(
                nowMinutes: 1439, startMinutes: 0, endMinutes: 24 * 60),
            "L31 full-day window active at 23:59")
        check(
            !IslandMetrics.quietHoursActive(
                nowMinutes: 1440, startMinutes: 0, endMinutes: 24 * 60),
            "L31 minutes clamped to 0...1439")
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let orig = (cfg.quietHoursEnabled, cfg.quietHoursStart, cfg.quietHoursEnd)
            cfg.quietHoursEnabled = true
            cfg.quietHoursStart = 22 * 60
            cfg.quietHoursEnd = 6 * 60
            check(
                defaults.bool(forKey: "quietHoursEnabled")
                    && defaults.integer(forKey: "quietHoursStart") == 1320
                    && defaults.integer(forKey: "quietHoursEnd") == 360,
                "L31 quiet hours persisted")
            cfg.quietHoursEnabled = false
            check(
                !cfg.isInQuietHours(at: Date()),
                "L31 disabled quiet hours inactive")
            cfg.quietHoursEnabled = true
            check(
                cfg.isInQuietHours(at: dateWith(minutesSinceMidnight: 23 * 60)),
                "L31 config active via date minutes")
            cfg.quietHoursEnabled = orig.0
            cfg.quietHoursStart = orig.1
            cfg.quietHoursEnd = orig.2
            defaults.removeObject(forKey: "quietHoursEnabled")
            defaults.removeObject(forKey: "quietHoursStart")
            defaults.removeObject(forKey: "quietHoursEnd")
        }

        // L32. LaunchAgent self-install: the app can create its own agent
        // plist pointing at the running binary, bootstrap the data dir, and
        // (re)load the agent — no setup.sh needed, so "Launch at login"
        // works for distributed users.
        do {
            let oldPath = LaunchAgent.plistPath
            let oldRunner = LaunchAgent.processRunner
            let oldBin = LaunchAgent.defaultBinaryPath
            let tmp = NSTemporaryDirectory() + "/bantay-l32-\(UUID().uuidString)"
            let dataDir = tmp + "/Data"
            let plist = tmp + "/agent.plist"
            try? FileManager.default.createDirectory(
                atPath: tmp, withIntermediateDirectories: true)
            LaunchAgent.plistPath = plist
            LaunchAgent.defaultBinaryPath = tmp + "/Bantay-TUI.app/Contents/MacOS/bantay"

            var calls: [[String]] = []
            LaunchAgent.processRunner = { args in
                calls.append(args)
                return 0
            }

            let content = LaunchAgent.plistContent(
                binaryPath: LaunchAgent.defaultBinaryPath, dataDir: dataDir)
            check(
                content.contains("com.bantay-tui.agent"),
                "L32 plist has agent label")
            check(
                content.contains(LaunchAgent.defaultBinaryPath),
                "L32 plist runs the app binary")
            check(
                content.contains("RunAtLoad") && content.contains("KeepAlive"),
                "L32 plist run-at-load and keep-alive flags")
            check(
                content.contains(dataDir + "/bantay.log")
                    && content.contains(dataDir + "/bantay.err"),
                "L32 plist log paths under data dir")

            LaunchAgent.install(dataDir: dataDir)
            check(
                FileManager.default.fileExists(atPath: plist),
                "L32 install writes plist")
            check(
                FileManager.default.fileExists(atPath: dataDir + "/agent-events.jsonl"),
                "L32 install bootstraps events file")
            check(
                calls.contains(["bootout", "gui/\(getuid())/\(LaunchAgent.label)"]),
                "L32 install boots out first")
            check(
                calls.contains(["bootstrap", "gui/\(getuid())", plist]),
                "L32 install bootstraps agent")

            let second = try? String(contentsOfFile: plist, encoding: .utf8)
            check(second == content, "L32 install idempotent")

            try? FileManager.default.removeItem(atPath: plist)
            calls = []
            LaunchAgent.setLaunchAtLogin(true)
            check(
                FileManager.default.fileExists(atPath: plist),
                "L32 enable self-installs plist when absent")
            check(
                calls.contains { $0.first == "bootstrap" },
                "L32 enable bootstraps after install")

            calls = []
            LaunchAgent.setLaunchAtLogin(false)
            check(
                !FileManager.default.fileExists(atPath: plist),
                "L32 disable removes plist")
            check(
                calls.first == ["bootout", "gui/\(getuid())/\(LaunchAgent.label)"],
                "L32 disable boots out")

            calls = []
            var bootstrapFailed = false
            LaunchAgent.processRunner = { args in
                calls.append(args)
                if args.first == "bootstrap" {
                    bootstrapFailed = true
                    return 1
                }
                return 0
            }
            LaunchAgent.install(dataDir: dataDir)
            check(
                bootstrapFailed && calls.contains { $0.first == "load" },
                "L32 legacy load fallback on bootstrap failure")

            try? FileManager.default.removeItem(atPath: tmp)
            LaunchAgent.plistPath = oldPath
            LaunchAgent.processRunner = oldRunner
            LaunchAgent.defaultBinaryPath = oldBin
        }

        // L33. Fallback event promotion picks the MOST severe unchanged agent
        // (kilo review finding): `best` is severity-ascending, so the fallback
        // must take `.last`, not `.first`.
        var seen33: [String: AgentEventKind] = [:]
        let first33 = AgentEventManager.update(
            from: [
                agent("kilo", "working", pane: "w3:p1"),
                agent("freebuff", "blocked", pane: "w3:p2"),
            ],
            lastSeenKinds: &seen33,
            current: nil)
        check(
            first33.events.contains { $0.kind == .accessRequest },
            "L33 blocked agent emits on first poll")
        let second33 = AgentEventManager.update(
            from: [
                agent("kilo", "working", pane: "w3:p1"),
                agent("freebuff", "blocked", pane: "w3:p2"),
            ],
            lastSeenKinds: &seen33,
            current: nil)
        check(
            second33.events.first?.source == "freebuff",
            "L33 fallback promotes most severe (got \(String(describing: second33.events.first?.source)))"
        )
        check(
            second33.events.first?.playSound == false,
            "L33 fallback reshow is silent")

        // L34. Hidden-island notifications: an approval arriving while the
        // island is hidden (snoozed / hide-at-startup) must never be missed
        // silently. Notification only for approval-ish kinds, never when the
        // island is showing the event (no double signal), opt-in by default.
        check(
            IslandMetrics.shouldPostNotification(
                islandVisible: false, notifyWhenHidden: true, kind: .accessRequest),
            "L34 hidden island notifies on approval")
        check(
            IslandMetrics.shouldPostNotification(
                islandVisible: false, notifyWhenHidden: true, kind: .waiting),
            "L34 hidden island notifies on waiting")
        check(
            !IslandMetrics.shouldPostNotification(
                islandVisible: false, notifyWhenHidden: true, kind: .progress),
            "L34 no notification for progress")
        check(
            !IslandMetrics.shouldPostNotification(
                islandVisible: false, notifyWhenHidden: true, kind: .completed),
            "L34 no notification for completed")
        check(
            !IslandMetrics.shouldPostNotification(
                islandVisible: false, notifyWhenHidden: true, kind: .idle),
            "L34 no notification for idle")
        check(
            !IslandMetrics.shouldPostNotification(
                islandVisible: false, notifyWhenHidden: false, kind: .accessRequest),
            "L34 feature off never notifies")
        check(
            !IslandMetrics.shouldPostNotification(
                islandVisible: true, notifyWhenHidden: true, kind: .accessRequest),
            "L34 visible island shows event, no notification")
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let orig = cfg.notifyWhenHidden
            cfg.notifyWhenHidden = true
            check(
                defaults.bool(forKey: "notifyWhenHidden"),
                "L34 notify toggle persisted")
            cfg.notifyWhenHidden = orig
            defaults.removeObject(forKey: "notifyWhenHidden")
        }

        // L35. herdr integration self-install for distributed users: the app
        // writes its own event-adapter script + plugin manifest (absolute
        // paths, no repo checkout) and registers via `plugin.link`.
        do {
            let tmp = NSTemporaryDirectory() + "/bantay-l35-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(
                atPath: tmp, withIntermediateDirectories: true)
            let dataDir = tmp + "/Data"
            let manifest = dataDir + "/herdr-plugin.toml"
            let adapterPath = dataDir + "/event-adapter.mjs"

            let content = HerdrPluginInstaller.manifestContent(dataDir: dataDir)
            check(
                content.contains("id = \"bantay-tui.integration\""),
                "L35 manifest keeps plugin id")
            check(
                content.contains("pane.agent_status_changed"),
                "L35 manifest wires status events")
            check(
                content.contains(adapterPath),
                "L35 manifest points at absolute adapter path")
            check(
                content.contains("command = [\"node\", \"\(adapterPath)\"]"),
                "L35 manifest command line is well-formed TOML")
            check(
                !content.contains(adapterPath + "\"\"]"),
                "L35 manifest has no doubled quote")
            check(
                !content.contains("scripts/setup.sh")
                    && !content.contains("scripts/event-adapter.mjs"),
                "L35 manifest has no repo-relative script references")

            if let repo = FileManager.default.contents(
                atPath: FileManager.default.currentDirectoryPath + "/scripts/event-adapter.mjs"),
                let repoText = String(data: repo, encoding: .utf8)
            {
                check(
                    HerdrPluginInstaller.adapterScript == repoText,
                    "L35 embedded adapter matches repo script (no drift)")
            } else {
                check(false, "L35 repo event-adapter.mjs unreadable")
            }

            check(
                !HerdrPluginInstaller.isInstalled(manifestPath: manifest),
                "L35 not installed before install")
            check(
                HerdrPluginInstaller.install(dataDir: dataDir, manifestPath: manifest),
                "L35 install succeeds")
            check(
                FileManager.default.fileExists(atPath: adapterPath)
                    && FileManager.default.fileExists(atPath: manifest),
                "L35 install writes both files")
            check(
                HerdrPluginInstaller.isInstalled(manifestPath: manifest),
                "L35 installed after install")
            let firstManifest = try? String(contentsOfFile: manifest, encoding: .utf8)
            let firstAdapter = try? String(contentsOfFile: adapterPath, encoding: .utf8)
            _ = HerdrPluginInstaller.install(dataDir: dataDir, manifestPath: manifest)
            let secondManifest = try? String(contentsOfFile: manifest, encoding: .utf8)
            let secondAdapter = try? String(contentsOfFile: adapterPath, encoding: .utf8)
            check(
                firstManifest == secondManifest && firstAdapter == secondAdapter,
                "L35 install idempotent")

            HerdrPluginInstaller.uninstall(manifestPath: manifest)
            check(
                !FileManager.default.fileExists(atPath: adapterPath)
                    && !FileManager.default.fileExists(atPath: manifest),
                "L35 uninstall removes both files")
            check(
                !HerdrPluginInstaller.isInstalled(manifestPath: manifest),
                "L35 not installed after uninstall")
            HerdrPluginInstaller.uninstall(manifestPath: manifest)
            check(true, "L35 uninstall tolerates missing files")

            try? FileManager.default.removeItem(atPath: tmp)
        }

        // L36. ProjectContext (wave 2): project basename + git branch from
        // .git/HEAD, offline; detached HEAD and non-git dirs handled; nil
        // when no cwd. Roster rows read "project · branch" not bare tool names.
        do {
            let tmp = NSTemporaryDirectory() + "/bantay-l36-\(UUID().uuidString)"
            let gitDir = tmp + "/bantay-tui"
            try? FileManager.default.createDirectory(
                atPath: gitDir + "/.git", withIntermediateDirectories: true)
            try? "ref: refs/heads/main\n".write(
                toFile: gitDir + "/.git/HEAD", atomically: true, encoding: .utf8)
            let ctx = ProjectContext(cwd: gitDir)
            check(ctx.project == "bantay-tui", "L36 project is dir basename")
            check(ctx.branch == "main", "L36 branch parsed from HEAD")
            check(ctx.isGit, "L36 git repo detected")

            let detachedDir = tmp + "/detached"
            try? FileManager.default.createDirectory(
                atPath: detachedDir + "/.git", withIntermediateDirectories: true)
            try? "a1b2c3d4f5\n".write(
                toFile: detachedDir + "/.git/HEAD", atomically: true, encoding: .utf8)
            let detached = ProjectContext(cwd: detachedDir)
            check(
                detached.branch == "detached" && detached.isGit,
                "L36 detached HEAD labeled")

            let plainDir = tmp + "/plain"
            try? FileManager.default.createDirectory(
                atPath: plainDir, withIntermediateDirectories: true)
            let plain = ProjectContext(cwd: plainDir)
            check(!plain.isGit && plain.branch == nil, "L36 non-git dir has no branch")

            let snapshot = AgentSnapshot(
                id: "p1", source: "claude", kind: .progress, title: nil, message: nil,
                paneId: "1-1", workspaceId: nil, cwd: gitDir,
                variance: nil, choices: nil, startedAt: nil,
                projectContext: ProjectContext(cwd: gitDir))
            check(
                snapshot.projectContext?.project == "bantay-tui"
                    && snapshot.projectContext?.branch == "main",
                "L36 snapshot surfaces cached project context")
            let noCwd = AgentSnapshot(
                id: "p2", source: "claude", kind: .progress, title: nil, message: nil,
                paneId: "1-2", workspaceId: nil, cwd: nil,
                variance: nil, choices: nil, startedAt: nil,
                projectContext: nil)
            check(noCwd.projectContext == nil, "L36 no cwd means no context")

            try? FileManager.default.removeItem(atPath: tmp)
        }

        // L37. F8 attention-only filter: only needs-input and failed agents
        // survive; order preserved; config toggle defaults off and persists.
        do {
            let mk = { (id: String, kind: AgentEventKind) in
                AgentSnapshot(
                    id: id, source: id, kind: kind, title: nil, message: nil,
                    paneId: nil, workspaceId: nil, cwd: nil,
                    variance: nil, choices: nil, startedAt: nil,
                    projectContext: nil)
            }
            let roster = [
                mk("a", .progress), mk("b", .accessRequest), mk("c", .completed),
                mk("d", .failed), mk("e", .idle), mk("f", .waiting),
            ]
            let attention = IslandMetrics.attentionFilter(roster)
            check(
                attention.map(\.id) == ["b", "d", "f"],
                "L37 attention filter keeps needs-input + failed (got \(attention.map(\.id)))")
            let none = IslandMetrics.attentionFilter([mk("a", .progress), mk("c", .completed)])
            check(none.isEmpty, "L37 attention filter empty when nothing needs input")
            let empty = IslandMetrics.attentionFilter([])
            check(empty.isEmpty, "L37 attention filter empty roster safe")

            MainActor.assumeIsolated {
                let defaults = UserDefaults.standard
                let cfg = NotchHUDConfig.shared
                let orig = cfg.attentionFilterEnabled
                check(cfg.attentionFilterEnabled == false, "L37 attention tab default off")
                cfg.attentionFilterEnabled = true
                check(
                    defaults.bool(forKey: "attentionFilterEnabled"),
                    "L37 attention toggle persisted")
                cfg.attentionFilterEnabled = orig
                defaults.removeObject(forKey: "attentionFilterEnabled")
            }
        }

        // L38. F9 completion recents: completed/failed work arriving while
        // inactive is retained, capped, ordered newest-first, and cleared
        // when the expanded panel acknowledges it. Active work is not noisy.
        MainActor.assumeIsolated {
            let manager = AgentEventManager(
                eventsFileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("lc-l38-\(UUID().uuidString).jsonl"),
                capture: false)
            manager.setActive(false)
            for index in 0..<7 {
                manager.publishEventForTesting(
                    AgentEvent(
                        source: "agent-\(index)",
                        kind: index.isMultiple(of: 2) ? .completed : .failed,
                        title: "result \(index)", message: nil, paneId: "p\(index)",
                        workspaceId: nil, variance: nil, choices: nil,
                        playSound: false, persistent: false))
            }
            check(manager.recentCompletions.count == 5, "L38 recents capped at five")
            check(
                manager.recentCompletions.first?.source == "agent-6",
                "L38 recents newest first")
            manager.setActive(true)
            manager.publishEventForTesting(
                AgentEvent(
                    source: "active", kind: .completed, title: "visible", message: nil,
                    paneId: "active", workspaceId: nil, variance: nil, choices: nil,
                    playSound: false, persistent: false))
            check(
                manager.recentCompletions.count == 5,
                "L38 active completion does not add unread recent")
            manager.markRecentCompletionsSeen()
            check(manager.recentCompletions.isEmpty, "L38 expand acknowledges recents")
        }

        // L39. F13 stable layout: empty and one-row rosters reserve the same
        // viewport; growth caps at available height; negative counts are safe.
        let emptyHeight = IslandMetrics.stableRosterHeight(
            agentCount: 0, availableHeight: 200)
        let oneHeight = IslandMetrics.stableRosterHeight(
            agentCount: 1, availableHeight: 200)
        let cappedHeight = IslandMetrics.stableRosterHeight(
            agentCount: 20, availableHeight: 100)
        let negativeHeight = IslandMetrics.stableRosterHeight(
            agentCount: -3, availableHeight: 200)
        check(emptyHeight == oneHeight, "L39 empty and one-row heights stable")
        check(cappedHeight == 100, "L39 roster height caps at available viewport")
        check(negativeHeight == oneHeight, "L39 negative agent count is safe")

        // L40. F11 pin/hover policy: composing and pinned panels stay open;
        // an unpinned expanded panel may collapse after hover grace.
        check(
            !IslandMetrics.shouldCollapseOnHoverExit(
                isExpanded: true, isComposing: false, isPinned: true),
            "L40 pinned panel ignores hover exit")
        check(
            !IslandMetrics.shouldCollapseOnHoverExit(
                isExpanded: true, isComposing: true, isPinned: false),
            "L40 composing panel ignores hover exit")
        check(
            IslandMetrics.shouldCollapseOnHoverExit(
                isExpanded: true, isComposing: false, isPinned: false),
            "L40 unpinned panel collapses after grace")
        check(
            !IslandMetrics.shouldCollapseOnHoverExit(
                isExpanded: false, isComposing: false, isPinned: false),
            "L40 closed panel never collapses")
        check(
            IslandMetrics.hoverExitGrace >= 0.25,
            "L40 hover grace is at least 250ms")

        // L42. F11 pin persistence: user-driven collapse (hover exit, hotkey
        // toggle, display re-anchor) keeps the pin; zero agents and explicit
        // unpin clear it; persistence can be opted out wholesale; the pin
        // never resurrects an empty expanded panel; config facet defaults off
        // and round-trips through UserDefaults.
        do {
            let persist = true
            check(
                IslandMetrics.pinAfterCollapse(
                    reason: .hoverExit, wasPinned: true, persistAcrossCollapse: persist),
                "L42 pin persists on hover exit")
            check(
                IslandMetrics.pinAfterCollapse(
                    reason: .hotkeyToggle, wasPinned: true, persistAcrossCollapse: persist),
                "L42 pin persists on hotkey toggle")
            check(
                IslandMetrics.pinAfterCollapse(
                    reason: .displayReanchor, wasPinned: true, persistAcrossCollapse: persist),
                "L42 pin persists on display re-anchor")
            check(
                !IslandMetrics.pinAfterCollapse(
                    reason: .agentsEmpty, wasPinned: true, persistAcrossCollapse: persist),
                "L42 pin clears on zero agents")
            check(
                !IslandMetrics.pinAfterCollapse(
                    reason: .explicitUnpin, wasPinned: true, persistAcrossCollapse: persist),
                "L42 pin clears on explicit unpin")
            check(
                !IslandMetrics.pinAfterCollapse(
                    reason: .agentsEmpty, wasPinned: false, persistAcrossCollapse: persist),
                "L42 already-unpinned stays unpinned on agents empty")
            for reason: IslandMetrics.PinCollapseReason in [
                .hoverExit, .hotkeyToggle, .displayReanchor, .agentsEmpty, .explicitUnpin,
            ] {
                check(
                    !IslandMetrics.pinAfterCollapse(
                        reason: reason, wasPinned: true, persistAcrossCollapse: false),
                    "L42 persistence-off clears pin on \(reason)")
            }
            check(
                IslandMetrics.pinShouldExpand(hasAgents: true),
                "L42 pin expands when agents exist")
            check(
                !IslandMetrics.pinShouldExpand(hasAgents: false),
                "L42 pin never resurrects an empty panel")
        }

        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let orig = cfg.panelPinned
            defaults.removeObject(forKey: "panelPinned")
            cfg.panelPinned = false
            check(cfg.panelPinned == false, "L42 panelPinned default off")
            cfg.panelPinned = true
            check(defaults.bool(forKey: "panelPinned"), "L42 panelPinned persisted")
            cfg.panelPinned = false
            check(
                defaults.bool(forKey: "panelPinned") == false,
                "L42 panelPinned unpin persisted")
            cfg.panelPinned = orig
            defaults.removeObject(forKey: "panelPinned")
        }

        // L44. Plan 016 §1d — non-destructive Claude hook merging. The five
        // adversarial gaps: false-positive matcher, corrupt/foreign `hooks`
        // shape, entry-level shape leak, data loss on unreadable settings.json,
        // and cross-port re-merge.
        do {
            func dictEquals(_ a: [String: Any], _ b: [String: Any]) -> Bool {
                (a as NSDictionary).isEqual(to: b)
            }

            // (a) Tightened matcher: true only for the Bantay command SHAPE
            // (curl + --data-binary @- + http://127.0.0.1:<digits>/events).
            let exactCommand = ClaudeHookInstaller.hookCommand(port: 41817)
            check(
                ClaudeHookInstaller.isBantayHook(["command": exactCommand]),
                "L44a exact hookCommand matches tightened matcher")
            check(
                ClaudeHookInstaller.isBantayHook(
                    ["command": "curl -s -X POST --data-binary @- http://127.0.0.1:9999/events"]),
                "L44a old port matches (port-agnostic digits)")
            check(
                !ClaudeHookInstaller.isBantayHook(
                    ["command": "myagent --url http://127.0.0.1:8080/events"]),
                "L44a foreign agent URL is not a bantay hook")
            check(
                !ClaudeHookInstaller.isBantayHook(["command": "curl http://127.0.0.1/events"]),
                "L44a bare curl without data-binary is not a bantay hook")
            check(
                !ClaudeHookInstaller.isBantayHook(["command": "ssh -R 41817:localhost:41817"]),
                "L44a ssh reverse tunnel is not a bantay hook")
            check(
                !ClaudeHookInstaller.isBantayHook(
                    [
                        "command":
                            "sh -c 'curl -s -X POST --data-binary @- http://127.0.0.1:9999/events'"
                    ]),
                "L44a wrapped curl variant unmatched (survives, documented limitation)")

            // (b) Merge returns the input UNCHANGED when `hooks` exists but is
            // not a [String: Any] — never fabricate or replace.
            let stringHooks: [String: Any] = ["apiKeyHelper": "default", "hooks": "broken"]
            let mergedString = ClaudeHookInstaller.mergedSettings(
                existing: stringHooks, port: 41817)
            check(
                dictEquals(mergedString, stringHooks),
                "L44b merge leaves string hooks value unchanged")
            let arrayHooks: [String: Any] = [
                "hooks": [["type": "command", "command": "foreign-tool"]]
            ]
            let mergedArray = ClaudeHookInstaller.mergedSettings(existing: arrayHooks, port: 41817)
            check(
                dictEquals(mergedArray, arrayHooks),
                "L44b merge leaves array hooks value unchanged")
            let oddEventHooks: [String: Any] = ["hooks": ["PermissionPrompt": "not-an-array"]]
            let mergedOdd = ClaudeHookInstaller.mergedSettings(existing: oddEventHooks, port: 41817)
            let mergedOddHooks = mergedOdd["hooks"] as? [String: Any]
            check(
                mergedOddHooks?["PermissionPrompt"] as? String == "not-an-array",
                "L44b merge preserves non-conforming event value (no overwrite)")
            check(
                (mergedOddHooks?["Stop"] as? [[String: Any]])?.count == 1,
                "L44b merge still installs bantay hooks for absent events")

            // (c) Removal with a non-array `hooks` value returns the input
            // unchanged; opaque event values survive alongside real removal.
            let removedString = ClaudeHookInstaller.removingBantayHooks(from: stringHooks)
            check(
                dictEquals(removedString, stringHooks),
                "L44c removal leaves string hooks value unchanged")
            let removedOdd = ClaudeHookInstaller.removingBantayHooks(from: oddEventHooks)
            check(
                dictEquals(removedOdd, oddEventHooks),
                "L44c removal preserves non-conforming event value")
            let mixedHooks: [String: Any] = [
                "hooks": [
                    "PermissionPrompt": "opaque",
                    "Stop": [
                        [
                            "matcher": "",
                            "hooks": [
                                ["type": "command", "command": exactCommand]
                            ],
                        ]
                    ],
                ]
            ]
            let removedMixed = ClaudeHookInstaller.removingBantayHooks(from: mixedHooks)
            let removedMixedHooks = removedMixed["hooks"] as? [String: Any]
            check(
                removedMixedHooks?["PermissionPrompt"] as? String == "opaque",
                "L44c opaque event value preserved while bantay Stop removed")
            check(
                removedMixedHooks?["Stop"] == nil,
                "L44c bantay-only Stop still removed alongside opaque value")

            // (d) Cross-port re-merge: settings with a Bantay entry at port
            // 41000 + a foreign entry, merged at 41817, yield exactly one
            // Bantay entry per event and preserve the foreign entry (no dup).
            let oldPortCommand = "curl -s -X POST --data-binary @- http://127.0.0.1:41000/events"
            let crossPortSettings: [String: Any] = [
                "hooks": [
                    "PermissionPrompt": [
                        [
                            "matcher": "bantay-old",
                            "hooks": [["type": "command", "command": oldPortCommand]],
                        ],
                        [
                            "matcher": "",
                            "hooks": [["type": "command", "command": "foreign-tool"]],
                        ],
                    ],
                    "Stop": [
                        [
                            "matcher": "",
                            "hooks": [["type": "command", "command": oldPortCommand]],
                        ]
                    ],
                ]
            ]
            let crossMerged = ClaudeHookInstaller.mergedSettings(
                existing: crossPortSettings, port: 41817)
            let crossPP =
                (crossMerged["hooks"] as? [String: Any])?["PermissionPrompt"]
                as? [[String: Any]]
            let crossStop =
                (crossMerged["hooks"] as? [String: Any])?["Stop"]
                as? [[String: Any]]
            check(
                crossPP?.count == 2,
                "L44d cross-port merge yields two PermissionPrompt entries (got \(crossPP?.count ?? -1))"
            )
            check(
                crossStop?.count == 1,
                "L44d cross-port merge yields one Stop entry (got \(crossStop?.count ?? -1))")
            let crossBantayCount = (crossPP ?? []).filter {
                ClaudeHookInstaller.isBantayEntry($0)
            }.count
            check(
                crossBantayCount == 1,
                "L44d exactly one bantay PermissionPrompt entry after cross-port merge (got \(crossBantayCount))"
            )
            let crossForeignSurvives = (crossPP ?? []).contains {
                ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String == "foreign-tool"
            }
            check(
                crossForeignSurvives,
                "L44d foreign entry survives cross-port merge")

            // (e) ClaudeHookWriteDecision.decide table: abort whenever the file
            // exists but did not parse, regardless of install/removal intent.
            let sample: [String: Any] = ["a": 1]
            switch ClaudeHookWriteDecision.decide(
                fileExists: false, parsed: false, merged: sample)
            {
            case .write(let payload):
                check(dictEquals(payload, sample), "L44e no file -> write (fresh install)")
            case .abort:
                check(false, "L44e no file -> write (fresh install)")
            }
            switch ClaudeHookWriteDecision.decide(
                fileExists: true, parsed: false, merged: sample)
            {
            case .abort:
                check(true, "L44e unparseable existing file aborts install")
            case .write:
                check(false, "L44e unparseable existing file aborts install")
            }
            switch ClaudeHookWriteDecision.decide(
                fileExists: true, parsed: false, merged: sample)
            {
            case .abort:
                check(true, "L44e unparseable existing file aborts removal")
            case .write:
                check(false, "L44e unparseable existing file aborts removal")
            }
            switch ClaudeHookWriteDecision.decide(
                fileExists: true, parsed: true, merged: sample)
            {
            case .write(let payload):
                check(dictEquals(payload, sample), "L44e parsed existing file writes merged")
            case .abort:
                check(false, "L44e parsed existing file writes merged")
            }

            // Re-assert the L28/L28b legacy corpus still holds against the
            // tightened matcher: the exact hookCommand output must match.
            let l28Entry: [String: Any] = [
                "matcher": "bantay",
                "hooks": [["type": "command", "command": exactCommand]],
            ]
            check(
                ClaudeHookInstaller.isBantayEntry(l28Entry),
                "L44 legacy L28 bantay entry still recognized by tightened matcher")
            let remergeSame = ClaudeHookInstaller.mergedSettings(
                existing: ["hooks": ["PermissionPrompt": [foreignPermission, l28Entry]]],
                port: 41817)
            let remergeSamePP =
                (remergeSame["hooks"] as? [String: Any])?["PermissionPrompt"]
                as? [[String: Any]]
            check(
                remergeSamePP?.count == 2,
                "L44 legacy L28b same-port re-merge still no-dup (got \(remergeSamePP?.count ?? -1))"
            )

            // (f) Legacy-shape hooks remain removable: a curl invocation that
            // pipes stdin via `-d @-` / `--data @-` (pre-1d installs) must be
            // recognized by the owned matcher and removed, while a foreign
            // command that merely mentions a localhost URL still never matches.
            let legacyDataCommand = "curl -s -X POST -d @- http://127.0.0.1:41817/events"
            check(
                ClaudeHookInstaller.isLegacyBantayHook(["command": legacyDataCommand]),
                "L44f legacy -d @- hook recognized")
            check(
                ClaudeHookInstaller.isLegacyBantayHook(
                    ["command": "curl -s -X POST --data @- http://127.0.0.1:9999/events"]),
                "L44f legacy --data @- hook recognized (port-agnostic)")
            check(
                !ClaudeHookInstaller.isLegacyBantayHook(
                    ["command": "myagent --url http://127.0.0.1:8080/events"]),
                "L44f foreign URL not matched by legacy matcher")
            check(
                !ClaudeHookInstaller.isLegacyBantayHook(["command": "curl http://127.0.0.1/events"]
                ),
                "L44f legacy matcher still requires stdin @-")
            check(
                ClaudeHookInstaller.isOwnedBantayHook(["command": legacyDataCommand]),
                "L44f owned matcher covers legacy command")
            check(
                ClaudeHookInstaller.isOwnedBantayHook(["command": exactCommand]),
                "L44f owned matcher covers current command")
            let legacyEntry: [String: Any] = [
                "matcher": "legacy-bantay",
                "hooks": [["type": "command", "command": legacyDataCommand]],
            ]
            check(
                ClaudeHookInstaller.isBantayEntry(legacyEntry),
                "L44f legacy entry recognized for removal")
            let removedLegacy = ClaudeHookInstaller.removingBantayHooks(
                from: ["hooks": ["PermissionPrompt": [legacyEntry]]])
            let removedLegacyHooks =
                (removedLegacy["hooks"] as? [String: Any])?["PermissionPrompt"]
                as? [[String: Any]]
            check(
                removedLegacyHooks == nil || removedLegacyHooks?.isEmpty == true,
                "L44f legacy hook actually removed")
        }

        // L43. ProcessRunner timeout clamp (plan 016 1c): negative and zero
        // request the 0.5s floor, enormous values cap at 120s, and the pane
        // list variants stay exact after the async migration.
        check(
            ProcessRunner.clampedTimeout(-5) == 0.5,
            "L43 negative timeout clamps to floor")
        check(
            ProcessRunner.clampedTimeout(0) == 0.5,
            "L43 zero timeout clamps to floor")
        check(
            ProcessRunner.clampedTimeout(0.75) == 0.75,
            "L43 in-range timeout unchanged")
        check(
            ProcessRunner.clampedTimeout(3600) == 120,
            "L43 huge timeout clamps to cap")
        check(
            ProcessRunner.clampedTimeout(-Double.infinity) == 0.5,
            "L43 -inf timeout clamps to floor")
        let variantsAfterMigration = HerdrSocketAdapter.paneListCommandVariants()
        check(
            variantsAfterMigration
                == [["pane", "list", "--format", "json"], ["pane", "list"]],
            "L43 pane list variants unchanged after async migration (got \(variantsAfterMigration))"
        )

        // L46. Plan 016 §3b — token rate-limit indicators. rate() is pure over
        // transcript JSONL timestamps; rateLevel maps tokens/min to a color.
        func usageLine(_ timestamp: String, input: Int, output: Int = 0) -> String {
            """
            {"type":"assistant","message":{"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"\(timestamp)"}
            """
        }
        let now = UsageParser.parseTimestamp(usageLine("2026-08-04T12:01:00Z", input: 0))!
        let threeLines = [
            usageLine("2026-08-04T12:00:00Z", input: 100),
            usageLine("2026-08-04T12:00:30Z", input: 100),
            usageLine("2026-08-04T12:01:00Z", input: 100),
        ]
        let zeroWindow = UsageTracker.rate(lines: threeLines, now: now, window: 0)
        check(zeroWindow.tokensPerMinute == nil, "L46 rate with 0s window is nil")
        let negativeWindow = UsageTracker.rate(lines: threeLines, now: now, window: -10)
        check(negativeWindow.tokensPerMinute == nil, "L46 rate with negative window is nil")
        let sixty = UsageTracker.rate(lines: threeLines, now: now, window: 60)
        check(
            sixty.tokensPerMinute.map { abs($0 - 300) < 0.001 } ?? false,
            "L46 rate over 60s window is 300/min (got \(sixty.tokensPerMinute.map(String.init(describing:)) ?? "nil"))"
        )
        check(sixty.lastSeen != nil, "L46 rate carries lastSeen")
        let sameTimestamp = UsageTracker.rate(
            lines: [
                usageLine("2026-08-04T12:00:00Z", input: 100),
                usageLine("2026-08-04T12:00:00Z", input: 100),
            ],
            now: now, window: 60)
        check(
            sameTimestamp.tokensPerMinute == nil,
            "L46 same-timestamp lines yield nil (no div by zero)")
        let missingTimestamps = UsageTracker.rate(
            lines: [
                #"{"type":"assistant","message":{"usage":{"input_tokens":10}}}"#,
                #"{"type":"assistant","message":{"usage":{"input_tokens":20}}}"#,
            ],
            now: now, window: 60)
        check(
            missingTimestamps.tokensPerMinute == nil && missingTimestamps.lastSeen == nil,
            "L46 missing timestamps yield nil")
        let outsideWindow = UsageTracker.rate(
            lines: [
                usageLine("2026-08-04T11:00:00Z", input: 1000),
                usageLine("2026-08-04T12:00:40Z", input: 50),
            ],
            now: now, window: 60)
        check(outsideWindow.tokensPerMinute == nil, "L46 stale line outside window excluded")
        check(
            UsageTracker.rateLevel(rate: 100, warn: 100) == .warn,
            "L46 rateLevel at exactly warn is warn")
        check(
            UsageTracker.rateLevel(rate: 200, warn: 100) == .red,
            "L46 rateLevel at exactly 2× warn is red")
        check(
            UsageTracker.rateLevel(rate: 250, warn: 100) == .red,
            "L46 rateLevel above 2× warn is red")
        check(
            UsageTracker.rateLevel(rate: 150, warn: 100) == .warn,
            "L46 rateLevel between warn and 2× is warn")
        check(
            UsageTracker.rateLevel(rate: 99.9, warn: 100) == .normal,
            "L46 rateLevel below warn is normal")
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            let cfg = NotchHUDConfig.shared
            let orig = cfg.usageRateWarnTokensPerMin
            check(
                cfg.usageRateWarnTokensPerMin == 5000,
                "L46 warn threshold default 5000 (got \(cfg.usageRateWarnTokensPerMin))")
            cfg.usageRateWarnTokensPerMin = 50
            check(
                cfg.usageRateWarnTokensPerMin == 100,
                "L46 warn threshold clamps at 100 (got \(cfg.usageRateWarnTokensPerMin))")
            cfg.usageRateWarnTokensPerMin = 2_000_000
            check(
                cfg.usageRateWarnTokensPerMin == 1_000_000,
                "L46 warn threshold clamps at 1_000_000 (got \(cfg.usageRateWarnTokensPerMin))")
            cfg.usageRateWarnTokensPerMin = 7500
            check(
                defaults.integer(forKey: "usageRateWarnTokensPerMin") == 7500,
                "L46 warn threshold persisted")
            cfg.usageRateWarnTokensPerMin = orig
            defaults.removeObject(forKey: "usageRateWarnTokensPerMin")
        }

        // L41. Plan 016 §1a — directory-keyed diff-stat cache. The key is
        // (id, cwd): standalone agents share paneId == nil so id alone
        // collides, and a summary is only valid for the cwd it was computed
        // in. The cache write must be keyed so a late old-cwd task can never
        // clobber the fresh new-cwd value.
        let repo1Key = IslandMetrics.DiffStatCacheKey(id: "claude", cwd: "/repo1")
        let repo2Key = IslandMetrics.DiffStatCacheKey(id: "claude", cwd: "/repo2")
        check(
            IslandMetrics.DiffStatCacheKey(id: "claude", cwd: "/repo1") == repo1Key,
            "L41 key equal for same id+cwd")
        check(repo1Key != repo2Key, "L41 key differs across cwds for same id")
        check(
            IslandMetrics.DiffStatCacheKey(id: "codex", cwd: "/repo1") != repo1Key,
            "L41 key differs across ids for same cwd")
        check(
            IslandMetrics.DiffStatCache.parseShortstat(
                " 1 file changed, 2 insertions(+), 3 deletions(-)")
                == "+2 −3",
            "L41 shortstat parses insertions+deletions")
        check(
            IslandMetrics.DiffStatCache.parseShortstat(" 1 file changed, 5 insertions(+)")
                == "+5 −0",
            "L41 insertion-only shortstat")
        check(
            IslandMetrics.DiffStatCache.parseShortstat(" 1 file changed, 7 deletions(-)")
                == "+0 −7",
            "L41 deletion-only shortstat")
        check(IslandMetrics.DiffStatCache.parseShortstat("") == nil, "L41 empty shortstat is nil")
        check(
            IslandMetrics.DiffStatCache.parseShortstat("nothing to see here") == nil,
            "L41 garbage shortstat is nil")
        check(
            IslandMetrics.DiffStatCache.parseShortstat(" 0 files changed") == nil,
            "L41 no-match shortstat is nil")

        let keyedCache: [IslandMetrics.DiffStatCacheKey: String] = [
            repo1Key: "+1 −0",
            repo2Key: "+9 −9",
            IslandMetrics.DiffStatCacheKey(id: "claude", cwd: "/repo3"): "+4 −4",
        ]
        let pruned = IslandMetrics.DiffStatCache.prune(keyedCache, liveKeys: [repo1Key, repo2Key])
        check(
            pruned[repo1Key] == "+1 −0" && pruned[repo2Key] == "+9 −9",
            "L41 prune keeps live keys")
        check(
            pruned[IslandMetrics.DiffStatCacheKey(id: "claude", cwd: "/repo3")] == nil,
            "L41 prune drops dead keys")

        // Simulated write race: cwd1 and cwd2 tasks both in flight for id A.
        // Either landing order leaves cache[A:cwd2] correct — the keyed write
        // never lets the stale cwd1 result occupy A's cwd2 slot.
        func keyedWrite(
            _ cache: inout [IslandMetrics.DiffStatCacheKey: String],
            _ key: IslandMetrics.DiffStatCacheKey, _ value: String
        ) {
            if cache[key] == nil { cache[key] = value }
        }
        var race1: [IslandMetrics.DiffStatCacheKey: String] = [:]
        keyedWrite(&race1, repo1Key, "+1 −0")
        keyedWrite(&race1, repo2Key, "+9 −9")
        check(race1[repo2Key] == "+9 −9", "L41 race order 1 keeps cwd2 value")
        var race2: [IslandMetrics.DiffStatCacheKey: String] = [:]
        keyedWrite(&race2, repo2Key, "+9 −9")
        keyedWrite(&race2, repo1Key, "+1 −0")
        check(race2[repo2Key] == "+9 −9", "L41 race order 2 keeps cwd2 value")
        check(race2[repo1Key] == "+1 −0", "L41 race order 2 keeps cwd1 value in own slot")
        let racedPruned = IslandMetrics.DiffStatCache.prune(race2, liveKeys: [repo2Key])
        check(racedPruned[repo2Key] == "+9 −9", "L41 race prune keeps live cwd2 key")
        check(racedPruned[repo1Key] == nil, "L41 race prune drops stale cwd1 key")

        // L48. Plan 016 §4a — multi-display: notch-less detection & centered
        // pill. The certified hasNotch heuristic: a display is NOTCHED only
        // when safeTop > 0 AND at least one auxiliary menu-bar area is
        // reported. Rows documented per case:
        //   safeTop 0  + aux (any)      -> false  (notch-less display; aux
        //                                       nil-ness alone is unreliable,
        //                                       macOS 13 vs 14 reporting)
        //   safeTop 24 + aux both 0     -> false  (safeTop alone isn't the
        //                                       notch; no aux -> fallback)
        //   safeTop 24 + any aux > 0    -> true   (certified notched, short
        //                                       menu bar)
        //   safeTop 37 + aux both 0     -> false
        //   safeTop 37 + any aux > 0    -> true   (certified notched)
        check(
            !IslandMetrics.hasNotch(safeTop: 0, auxLeft: 0, auxRight: 0),
            "L48 hasNotch(0,0,0) -> false")
        check(
            !IslandMetrics.hasNotch(safeTop: 0, auxLeft: 200, auxRight: 300),
            "L48 hasNotch(0,200,300) -> false (safeTop 0 is notch-less even with aux)")
        check(
            !IslandMetrics.hasNotch(safeTop: 0, auxLeft: 0, auxRight: 300),
            "L48 hasNotch(0,0,300) -> false (any aux, safeTop 0)")
        check(
            !IslandMetrics.hasNotch(safeTop: 24, auxLeft: 0, auxRight: 0),
            "L48 hasNotch(24,0,0) -> false (no aux areas reported)")
        check(
            IslandMetrics.hasNotch(safeTop: 24, auxLeft: 200, auxRight: 300),
            "L48 hasNotch(24,200,300) -> true (certified notched)")
        check(
            IslandMetrics.hasNotch(safeTop: 24, auxLeft: 0, auxRight: 300),
            "L48 hasNotch(24,0,300) -> true (any aux > 0)")
        check(
            !IslandMetrics.hasNotch(safeTop: 37, auxLeft: 0, auxRight: 0),
            "L48 hasNotch(37,0,0) -> false (both aux 0)")
        check(
            IslandMetrics.hasNotch(safeTop: 37, auxLeft: 200, auxRight: 300),
            "L48 hasNotch(37,200,300) -> true (full notch)")
        check(
            IslandMetrics.hasNotch(safeTop: 37, auxLeft: 0, auxRight: 300),
            "L48 hasNotch(37,0,300) -> true (any aux > 0)")

        // Centered floating pill below the menu bar, clamped inside bounds at
        // 400×300 and at 5K.
        let smallScreen = CGRect(x: 0, y: 0, width: 400, height: 300)
        let pillSize = CGSize(width: 211, height: 36)
        let smallPill = IslandMetrics.floatingPillFrame(
            screenFrame: smallScreen, size: pillSize, menuBarHeight: 24)
        check(
            abs(smallPill.midX - smallScreen.midX) < 0.01,
            "L48 pill centered (midX == screen.midX) at 400x300 (got \(smallPill.midX))")
        check(
            smallPill.maxY <= smallScreen.maxY - 24 + 0.01,
            "L48 pill sits below menu bar (maxY \(smallPill.maxY) <= \(smallScreen.maxY - 24))")
        check(
            smallPill.minX >= 0 && smallPill.minY >= 0
                && smallPill.maxX <= smallScreen.maxX && smallPill.maxY <= smallScreen.maxY,
            "L48 pill inside 400x300 bounds (frame \(smallPill))")
        let bigScreen = CGRect(x: 0, y: 0, width: 5120, height: 2880)
        let bigPill = IslandMetrics.floatingPillFrame(
            screenFrame: bigScreen, size: pillSize, menuBarHeight: 24)
        check(
            abs(bigPill.midX - bigScreen.midX) < 0.01,
            "L48 pill centered at 5K (got \(bigPill.midX))")
        check(
            bigPill.minX >= 0 && bigPill.minY >= 0
                && bigPill.maxX <= bigScreen.maxX && bigPill.maxY <= bigScreen.maxY,
            "L48 pill inside 5K bounds (frame \(bigPill))")

        // topInset on a notch-less display falls back to the menu bar.
        check(
            IslandMetrics.topInset(safeTop: 0, menuBarHeight: 24) == 24,
            "L48 topInset(0,24) == 24")
        check(
            IslandMetrics.topInset(safeTop: 37, menuBarHeight: 24) == 37,
            "L48 topInset(37,24) == 37 (notched keeps safeTop)")

        // notchWidth falls back to notchlessFallbackWidth whenever any
        // decisive input is 0 (safeTop 0, or an aux side missing) and computes
        // a real width only for a certified notch with both aux areas.
        check(
            IslandMetrics.notchWidth(screenWidth: 1512, auxLeft: 0, auxRight: 0, safeTop: 0)
                == IslandMetrics.notchlessFallbackWidth,
            "L48 notchWidth fallback when safeTop 0")
        check(
            IslandMetrics.notchWidth(screenWidth: 1512, auxLeft: 0, auxRight: 300, safeTop: 37)
                == IslandMetrics.notchlessFallbackWidth,
            "L48 notchWidth fallback when auxLeft 0")
        check(
            IslandMetrics.notchWidth(screenWidth: 1512, auxLeft: 200, auxRight: 0, safeTop: 37)
                == IslandMetrics.notchlessFallbackWidth,
            "L48 notchWidth fallback when auxRight 0")
        check(
            IslandMetrics.notchWidth(screenWidth: 1512, auxLeft: 0, auxRight: 0, safeTop: 24)
                == IslandMetrics.notchlessFallbackWidth,
            "L48 notchWidth fallback when both aux 0")
        let notchedWidth = IslandMetrics.notchWidth(
            screenWidth: 1512, auxLeft: 200, auxRight: 300, safeTop: 24)
        check(
            abs(notchedWidth - 1014) < 0.01,
            "L48 notchWidth computed for certified notch (got \(notchedWidth))")

        // L17 ghost re-anchor stays green with the new notch-less pill
        // geometry: an on-screen pill is not a ghost; a pill parked at a
        // since-disconnected position is.
        check(
            IslandMetrics.DisplayAnchor.frameIsOnScreens(
                frame: smallPill, screens: [smallScreen, bigScreen]),
            "L48 pill frame lands on its own screen")
        check(
            !IslandMetrics.DisplayAnchor.needsReanchor(
                isVisible: true, windowFrame: smallPill, screens: [smallScreen, bigScreen]),
            "L48 on-screen pill needs no re-anchor")
        let ghostPill = CGRect(x: 6000, y: 3000, width: 211, height: 36)
        check(
            IslandMetrics.DisplayAnchor.needsReanchor(
                isVisible: true, windowFrame: ghostPill, screens: [smallScreen, bigScreen]),
            "L48 ghost pill off every screen needs re-anchor")
        check(
            !IslandMetrics.DisplayAnchor.needsReanchor(
                isVisible: false, windowFrame: ghostPill, screens: [smallScreen, bigScreen]),
            "L48 hidden ghost pill needs no re-anchor")

        // L45. Plan 016 §3a — peek panel overlay: pure tail cleaner + panel
        // placement. `LogFormatter.cleanedTail` must be safe against the
        // adversarial `pane read` cases (oversized single lines, ANSI/binary
        // garbage) while preserving CJK/emoji; `peekFrame` must dock beside
        // the island, clamp inside the screen, never overlap the island, and
        // align to the backing pixel grid.

        // cleanedTail: a 1000-line input suffixes to exactly maxLines (the
        // newest lines win).
        let thousandLines = (1...1000).map { "line \($0)" }.joined(separator: "\n")
        let tail6 = LogFormatter.cleanedTail(thousandLines, maxLines: 6, maxLineLength: 200)
        check(tail6.count == 6, "L45 tail suffixes to maxLines (got \(tail6.count))")
        check(tail6.last == "line 1000", "L45 tail keeps the newest line last")
        check(
            tail6.first == "line 995",
            "L45 tail keeps the newest 6 lines (got \(tail6.first ?? "nil"))")
        let tail200 = LogFormatter.cleanedTail(thousandLines, maxLines: 200, maxLineLength: 200)
        check(tail200.count == 200, "L45 tail at 200-line cap (got \(tail200.count))")

        // Blank / whitespace-only lines are dropped before suffixing.
        let padded = "  alpha  \n   \n\t\nbeta\n\n  \n\ngamma\n"
        let cleanPadded = LogFormatter.cleanedTail(padded, maxLines: 10, maxLineLength: 200)
        check(cleanPadded == ["alpha", "beta", "gamma"], "L45 whitespace-only lines dropped")

        // A 100k-char single line truncates to maxLineLength without throwing
        // (the A-corpus size from plan 006 Step 4).
        let hugeLine = String(repeating: "x", count: 100_000)
        let truncated = LogFormatter.cleanedTail(hugeLine, maxLines: 5, maxLineLength: 120)
        check(
            truncated.count == 1 && truncated[0].count == 120,
            "L45 100k-char line truncated to maxLineLength (got \(truncated.first?.count ?? -1) chars)"
        )

        // ANSI escape sequences are stripped so terminal garbage can't render.
        let ansi = "\u{1B}[31mred\u{1B}[0m \u{1B}[1;32mgreen\u{1B}[0m"
        let cleanedAnsi = LogFormatter.cleanedTail(ansi, maxLines: 10, maxLineLength: 200)
        check(cleanedAnsi == ["red green"], "L45 ANSI escapes stripped (got \(cleanedAnsi))")
        // Bare control characters (binary garbage) are also stripped.
        let binary = "ok\u{07}good\u{00}and"
        let cleanedBinary = LogFormatter.cleanedTail(binary, maxLines: 10, maxLineLength: 200)
        check(cleanedBinary == ["okgoodand"], "L45 control chars stripped (got \(cleanedBinary))")
        let twoCharEscape = LogFormatter.cleanedTail(
            "\u{1B}7 hello", maxLines: 10, maxLineLength: 200)
        check(twoCharEscape == ["hello"], "L45 two-char escape stripped (got \(twoCharEscape))")

        // CJK/emoji survive both cleaning and hard truncation (truncation
        // stays on grapheme-cluster boundaries).
        let unicodeLine = "你好世界 🚀 test 日本語"
        let cleanedUnicode = LogFormatter.cleanedTail(unicodeLine, maxLines: 10, maxLineLength: 200)
        check(
            cleanedUnicode == ["你好世界 🚀 test 日本語"],
            "L45 CJK/emoji preserved (got \(cleanedUnicode))")
        let unicodeTrunc = LogFormatter.cleanedTail("🚀🚀🚀🚀🚀", maxLines: 10, maxLineLength: 3)
        check(
            unicodeTrunc == ["🚀🚀🚀"],
            "L45 emoji truncation keeps whole graphemes (got \(unicodeTrunc))")

        // peekFrame: docks beside the island, clamps inside a 400×300 screen,
        // never overlaps the island, aligns to the backing pixel grid.
        let peekScreen = CGRect(x: 0, y: 0, width: 400, height: 300)
        let peekIsland = CGRect(x: 100, y: 0, width: 200, height: 36)
        let peek = IslandMetrics.peekFrame(
            anchor: peekIsland, screenFrame: peekScreen, size: CGSize(width: 380, height: 200))
        check(!peek.intersects(peekIsland), "L45 peek never overlaps the island (frame \(peek))")
        check(
            peek.minX >= peekScreen.minX && peek.minY >= peekScreen.minY
                && peek.maxX <= peekScreen.maxX && peek.maxY <= peekScreen.maxY,
            "L45 peek clamps inside 400x300 (frame \(peek))")
        check(
            peek.minX == peekIsland.maxX + IslandMetrics.peekGap,
            "L45 peek docks beside the island (frame \(peek))")

        // Left dock when the right side lacks room.
        let rightEdgeIsland = CGRect(x: 300, y: 0, width: 92, height: 36)
        let leftPeek = IslandMetrics.peekFrame(
            anchor: rightEdgeIsland, screenFrame: peekScreen, size: CGSize(width: 380, height: 200))
        check(
            leftPeek.maxX <= rightEdgeIsland.minX,
            "L45 peek docks left when right has no room (frame \(leftPeek))")
        check(!leftPeek.intersects(rightEdgeIsland), "L45 left-docked peek avoids the island")

        // No side room: stacks below the island, still on-screen + disjoint.
        let fullWidthIsland = CGRect(x: 0, y: 0, width: 400, height: 36)
        let belowPeek = IslandMetrics.peekFrame(
            anchor: fullWidthIsland, screenFrame: peekScreen, size: CGSize(width: 380, height: 200))
        check(!belowPeek.intersects(fullWidthIsland), "L45 below-stacked peek avoids the island")
        check(
            belowPeek.minX >= 0 && belowPeek.minY >= 0
                && belowPeek.maxX <= 400 && belowPeek.maxY <= 300,
            "L45 below-stacked peek stays on-screen (frame \(belowPeek))")

        // Scale alignment: fractional inputs snap to the backing pixel grid.
        let fractionalIsland = CGRect(x: 100.5, y: 3.25, width: 200, height: 36)
        let alignedPeek = IslandMetrics.peekFrame(
            anchor: fractionalIsland, screenFrame: peekScreen,
            size: CGSize(width: 95.25, height: 201), scale: 2)
        check(
            alignedPeek.minY == 3.5,
            "L45 peek aligns to the 2x pixel grid (got \(alignedPeek.minY))")
        check(
            alignedPeek.maxY == 204.5,
            "L45 peek maxY aligns to the 2x grid (got \(alignedPeek.maxY))")
        check(!alignedPeek.intersects(fractionalIsland), "L45 aligned peek still avoids the island")

        // L49. Plan 016 §4b — arrow-key roster navigation. Pure rowIndex
        // model: no wrap at either end, safe on count 0/1, and strictly
        // monotonic. The UI seeds `current` with -1 (nothing focused → first
        // row) and `count` (nothing focused → last row) so the sentinels are
        // part of the contract.
        check(
            IslandMetrics.rowIndex(after: 0, count: 3) == 1,
            "L49 rowIndex(after 0 of 3) -> 1")
        check(
            IslandMetrics.rowIndex(after: 2, count: 3) == nil,
            "L49 down from last row is nil (no wrap)")
        check(
            IslandMetrics.rowIndex(before: 2, count: 3) == 1,
            "L49 rowIndex(before 2 of 3) -> 1")
        check(
            IslandMetrics.rowIndex(before: 0, count: 3) == nil,
            "L49 up from first row is nil (no wrap)")
        check(
            IslandMetrics.rowIndex(after: 0, count: 0) == nil,
            "L49 after on empty roster is nil")
        check(
            IslandMetrics.rowIndex(before: 0, count: 0) == nil,
            "L49 before on empty roster is nil")
        check(
            IslandMetrics.rowIndex(after: 0, count: 1) == nil,
            "L49 single row has no next (got \(String(describing: IslandMetrics.rowIndex(after: 0, count: 1))))"
        )
        check(
            IslandMetrics.rowIndex(before: 0, count: 1) == nil,
            "L49 single row has no previous (got \(String(describing: IslandMetrics.rowIndex(before: 0, count: 1))))"
        )
        check(
            IslandMetrics.rowIndex(after: -1, count: 3) == 0,
            "L49 sentinel -1 focuses first row (got \(String(describing: IslandMetrics.rowIndex(after: -1, count: 3))))"
        )
        check(
            IslandMetrics.rowIndex(before: 3, count: 3) == 2,
            "L49 sentinel count focuses last row (got \(String(describing: IslandMetrics.rowIndex(before: 3, count: 3))))"
        )
        check(
            IslandMetrics.rowIndex(after: 1, count: 2) == nil,
            "L49 down from penultimate of 2 is nil (no wrap)")
        check(
            IslandMetrics.rowIndex(before: 1, count: 2) == 0,
            "L49 up from second of 2 is first (monotonic, got \(String(describing: IslandMetrics.rowIndex(before: 1, count: 2))))"
        )
        var walk = 0
        var monotonic = true
        while let next = IslandMetrics.rowIndex(after: walk, count: 5) {
            if next != walk + 1 { monotonic = false }
            walk = next
        }
        check(monotonic && walk == 4, "L49 down-walk 0..4 is monotonic, no wrap (walk \(walk))")

        // MARK: - L47 global hotkey mapping (3c)
        // Documented table: ⌥Space=toggle (49), ⌥Y=approve top (16),
        // ⌥N=deny top (45), ⌥S=snooze 15m (1). Physical, layout-independent
        // keyCodes. Modifier exclusivity: only Option; any of Shift/Control/
        // Command disqualifies. Unknown keyCodes -> nil.
        let opt = NSEvent.ModifierFlags.option
        check(
            IslandMetrics.hotkeyAction(keyCode: 49, modifiers: [opt]) == .toggleIsland,
            "L47 49+option -> toggleIsland")
        check(
            IslandMetrics.hotkeyAction(keyCode: 16, modifiers: [opt]) == .approveTop,
            "L47 16+option -> approveTop")
        check(
            IslandMetrics.hotkeyAction(keyCode: 45, modifiers: [opt]) == .denyTop,
            "L47 45+option -> denyTop")
        check(
            IslandMetrics.hotkeyAction(keyCode: 1, modifiers: [opt]) == .snooze15,
            "L47 1+option -> snooze15")
        check(
            IslandMetrics.hotkeyAction(keyCode: 49, modifiers: [opt, .shift]) == nil,
            "L47 49+option+shift -> nil (exclusive)")
        check(
            IslandMetrics.hotkeyAction(keyCode: 49, modifiers: [opt, .control]) == nil,
            "L47 49+option+control -> nil (exclusive)")
        check(
            IslandMetrics.hotkeyAction(keyCode: 49, modifiers: [opt, .command]) == nil,
            "L47 49+option+command -> nil (exclusive)")
        check(
            IslandMetrics.hotkeyAction(keyCode: 49, modifiers: []) == nil,
            "L47 49 no modifiers -> nil")
        check(
            IslandMetrics.hotkeyAction(keyCode: 99, modifiers: [opt]) == nil,
            "L47 unknown keyCode -> nil")

        // L55. UDS event-ingest extension (plan 017 W2): HTTP-over-socket
        // reuses the IngestHTTP parser; the bare NDJSON form (a `token
        // <secret>` line followed by ONE event JSON line, then close)
        // validates payloads, rejects garbage and oversized input, resolves
        // the socket path with env override, and decides stale-socket
        // unlinking. Coexists with L11/L64 (TCP ingest + token auth).
        do {
            let token = NotchHUDConfig.generateIngestToken()
            let payload =
                #"{"v":1,"source":"aider","type":"access_request","title":"run tests","message":"Aider needs approval","paneId":null,"workspaceId":null,"variance":"yes-no","choices":null}"#

            // Form 1 — HTTP POST over the socket (curl --unix-socket ...).
            let httpBytes = Data(
                ("POST /events?token=\(token) HTTP/1.1\r\nHost: localhost\r\n"
                    + "Content-Length: \(payload.utf8.count)\r\n\r\n\(payload)").utf8)
            let udsHTTP = IngestHTTP.request(from: httpBytes)
            check(
                udsHTTP?.method == "POST" && udsHTTP?.token == token,
                "L55 HTTP-over-UDS parses via IngestHTTP")
            check(
                String(data: udsHTTP!.body, encoding: .utf8) == payload,
                "L55 HTTP-over-UDS body intact")
            check(
                !EventIngestServer.isBareLineRequest(httpBytes),
                "L55 complete HTTP request is not bare-line")

            // Form 2 — bare NDJSON form: `token <secret>` + one event line.
            let bareBytes = Data("token \(token)\n\(payload)\n".utf8)
            check(
                EventIngestServer.isBareLineRequest(bareBytes),
                "L55 bare-line buffer detected (no HTTP framing)")
            check(
                EventIngestServer.bareLineToken(from: "token \(token)") == token,
                "L55 token prefix line parses")
            check(
                EventIngestServer.bareLineToken(from: "token  ") == nil,
                "L55 empty token prefix rejected")
            check(
                EventIngestServer.bareLineToken(from: "notoken") == nil,
                "L55 non-token line rejected")
            check(
                EventIngestServer.validateBareLine(payload),
                "L55 valid payload passes bare-line validation")
            check(
                EventIngestServer.bareLineEvent(buffer: bareBytes, expectedToken: token)
                    == payload,
                "L55 bare-line form forwards the event line")
            let wrongToken = NotchHUDConfig.generateIngestToken()
            check(
                EventIngestServer.bareLineEvent(buffer: bareBytes, expectedToken: wrongToken)
                    == nil,
                "L55 wrong bare-line token rejected")
            check(
                EventIngestServer.bareLineEvent(
                    buffer: Data("token wrong\n\(payload)\n".utf8), expectedToken: token) == nil,
                "L55 bare form with bad token line rejected")
            check(
                !EventIngestServer.validateBareLine("not json at all"),
                "L55 non-JSON bare line rejected")
            check(
                !EventIngestServer.validateBareLine(#"{"type":"bogus"}"#),
                "L55 unknown event type rejected")
            check(
                EventIngestServer.bareLineEvent(
                    buffer: Data("token \(token)\nnot json\n".utf8),
                    expectedToken: token) == nil,
                "L55 bare form with non-JSON event rejected")
            check(
                EventIngestServer.bareLineEvent(
                    buffer: Data("token \(token)\n".utf8), expectedToken: token) == nil,
                "L55 bare form missing event line rejected")

            // Oversized (> 64 KiB) lines are rejected before buffer growth.
            let giant = Data(repeating: 0x61, count: EventIngestServer.maxIngestLineBytes + 1)
            check(EventIngestServer.isOversized(giant), "L55 >64 KiB line flagged oversized")
            check(
                !EventIngestServer.isOversized(Data("token x\n{}".utf8)),
                "L55 small buffer not oversized")

            // Path resolution: env override wins, default lives in app support.
            check(
                EventIngestServer.ingestSocketPath(
                    env: ["BANTAY_INGEST_SOCKET": "/tmp/bantay-ingest.sock"], home: "/Users/x")
                    == "/tmp/bantay-ingest.sock",
                "L55 BANTAY_INGEST_SOCKET override wins")
            check(
                EventIngestServer.ingestSocketPath(env: [:], home: "/Users/x")
                    == "/Users/x/Library/Application Support/Bantay-TUI/ingest.sock",
                "L55 default socket path in app support")
            check(
                EventIngestServer.ingestSocketPath(
                    env: ["BANTAY_INGEST_SOCKET": ""], home: "/Users/x")
                    == "/Users/x/Library/Application Support/Bantay-TUI/ingest.sock",
                "L55 empty override falls back to default")

            // Stale-socket handling: unlink a leftover socket file when the
            // bind failed; never unlink a bound listener's socket.
            check(
                EventIngestServer.shouldUnlinkStaleSocket(bindFailed: true, socketExists: true),
                "L55 stale socket file unlinked on bind failure")
            check(
                !EventIngestServer.shouldUnlinkStaleSocket(bindFailed: true, socketExists: false),
                "L55 no leftover file, no unlink")
            check(
                !EventIngestServer.shouldUnlinkStaleSocket(bindFailed: false, socketExists: true),
                "L55 live listener never unlinks")

            // Config: socket facet default ON (user-owned local socket, not a
            // network exposure like the default-off TCP port) + persisted.
            MainActor.assumeIsolated {
                let defaults = UserDefaults.standard
                let cfg = NotchHUDConfig.shared
                let orig = cfg.ingestSocketEnabled
                check(
                    cfg.ingestSocketEnabled,
                    "L55 ingest socket default on (user-owned local socket)")
                cfg.ingestSocketEnabled = false
                check(
                    defaults.bool(forKey: "ingestSocketEnabled") == false,
                    "L55 ingest socket toggle persisted")
                cfg.ingestSocketEnabled = orig
                defaults.removeObject(forKey: "ingestSocketEnabled")
            }
        }

        // MARK: - L52 zellij adapter (WI-2, plan 017)
        // `zellij ls` session listing: --short (name per line), --no-formatting
        // (name + age + optional suffix), default (ANSI), and JSON variants.
        // Unhandled/error output (empty stdout) must yield empty results.
        check(
            ZellijAdapter.parseSessions("") == [],
            "L52 empty/unhandled zellij ls stdout -> []")
        check(
            ZellijAdapter.parseSessions("foo\nbar\n") == ["foo", "bar"],
            "L52 zellij ls --short parses one name per line")
        let lsNoFormat =
            "foo [Created 2h ago]\nbar [Created 5m ago] (current)\n"
            + "dead [Created 1d ago] (EXITED - attach to resurrect)\n"
        check(
            ZellijAdapter.parseSessions(lsNoFormat) == ["foo", "bar", "dead"],
            "L52 zellij ls --no-formatting keeps names, drops age/suffix")
        check(
            ZellijAdapter.parseSessions(
                "\u{1b}[32;1mfoo\u{1b}[m [Created \u{1b}[35;1m2h\u{1b}[m ago]\n")
                == ["foo"],
            "L52 default (ANSI) zellij ls strips styling")
        check(
            ZellijAdapter.parseSessions(#"["alpha", "beta"]"#) == ["alpha", "beta"],
            "L52 zellij ls JSON string array parses")
        check(
            ZellijAdapter.parseSessions(#"[{"name": "one"}, {"name": "two"}]"#) == ["one", "two"],
            "L52 zellij ls JSON object array parses by name")
        check(
            ZellijAdapter.parseSessions("[{bad json") == [],
            "L52 malformed zellij ls JSON -> []")
        // Unhandled verbs never fabricate results.
        check(
            ZellijAdapter.supportsActionVerb("dump-screen"),
            "L52 dump-screen verb is in the 0.40+ action surface")
        check(
            !ZellijAdapter.supportsActionVerb("frobnicate-pane"),
            "L52 unknown action verb is rejected")
        // Verb construction (pure, documented zellij 0.40+ assumption).
        check(
            ZellijAdapter.listSessionsCommand() == ["ls", "--short"],
            "L52 session listing verb is `zellij ls --short`")
        check(
            ZellijAdapter.listPanesCommand(session: "s1")
                == ["--session", "s1", "action", "list-panes", "--json"],
            "L52 pane listing verb targets the session with --json")
        check(
            ZellijAdapter.captureCommand(session: "s1", pane: "terminal_3")
                == ["--session", "s1", "action", "dump-screen", "--pane-id", "terminal_3"],
            "L52 capture verb is dump-screen --pane-id")
        check(
            ZellijAdapter.focusCommand(session: "s1", pane: "terminal_3")
                == ["--session", "s1", "action", "focus-pane-id", "terminal_3"],
            "L52 focus verb is focus-pane-id")
        check(
            ZellijAdapter.sendKeysCommand(session: "s1", pane: "terminal_3", keys: ["y", "enter"])
                == [
                    "--session", "s1", "action", "send-keys", "--pane-id", "terminal_3", "y",
                    "Enter",
                ],
            "L52 send-keys verb maps herdr keys to zellij names")
        check(
            ZellijAdapter.writeCharsCommand(session: "s1", pane: "terminal_3", text: "echo hi")
                == [
                    "--session", "s1", "action", "write-chars", "--pane-id", "terminal_3",
                    "echo hi",
                ],
            "L52 sendLine verb is write-chars")
        // (session, pane) identity composition + drift on session kill.
        check(
            ZellijAdapter.composePaneId(session: "s1", pane: "terminal_3") == "s1|terminal_3",
            "L52 paneId composes (session, pane) into one string")
        check(
            ZellijAdapter.splitPaneId("s1|terminal_3")?.session == "s1"
                && ZellijAdapter.splitPaneId("s1|terminal_3")?.pane == "terminal_3",
            "L52 paneId splits back into (session, pane)")
        check(
            ZellijAdapter.splitPaneId("terminal_3") == nil,
            "L52 malformed paneId without a session -> nil")
        let drifted = ZellijAdapter.driftedPaneIds(
            paneIds: ["s1|terminal_1", "s2|terminal_2", "s3|terminal_1"],
            activeSessions: ["s1", "s3"])
        check(
            drifted == ["s2|terminal_2"],
            "L52 killed session drifts its pane ids (got \(drifted))")

        // L51. Plan 017 WI-1 — tmux adapter: dual-template `-F` pane parsing
        // (full 8-field + minimal 4-field shapes, tab/quoted variants),
        // `%N` -> `session:window.pane` id composition, extended PaneInfo
        // fields, PATH discovery, and detection wiring. The parser and
        // candidate paths are pure and harness-safe; the CLI verbs are
        // fire-and-forget and are never exercised here.
        let fullPanes = TmuxAdapter.parsePaneLines(
            "dev\t1\t2\t%12\t/dev/ttys003\t4242\tzsh\t/Users/me/proj")
        check(fullPanes.count == 1, "L51 full-shape line parses (got \(fullPanes.count))")
        let full = fullPanes[0]
        check(
            full.id == "dev:1.2",
            "L51 %N composes to session:window.pane (got \(full.id))")
        check(full.session == "dev", "L51 full session extracted")
        check(
            full.windowIndex == 1 && full.paneIndex == 2,
            "L51 full window/pane extracted (got \(String(describing: full.windowIndex)),\(String(describing: full.paneIndex)))"
        )
        check(
            full.tty == "/dev/ttys003",
            "L51 full tty extracted (got \(String(describing: full.tty)))")
        check(
            full.pid == 4242,
            "L51 full pid extracted (got \(String(describing: full.pid)))")
        check(
            full.currentCommand == "zsh",
            "L51 full current command extracted (got \(String(describing: full.currentCommand)))")
        check(
            full.currentPath == "/Users/me/proj",
            "L51 full current path extracted (got \(String(describing: full.currentPath)))")

        let minimalPanes = TmuxAdapter.parsePaneLines("dev\t1\t2\t%12\n")
        check(
            minimalPanes.count == 1,
            "L51 minimal-shape line parses (got \(minimalPanes.count))")
        let minimal = minimalPanes[0]
        check(
            minimal.id == "dev:1.2",
            "L51 minimal id composes (got \(minimal.id))")
        check(
            minimal.tty == nil && minimal.pid == nil,
            "L51 minimal lacks tty/pid")
        check(
            minimal.currentCommand == nil && minimal.currentPath == nil,
            "L51 minimal lacks command/path")

        let mixed = TmuxAdapter.parsePaneLines(
            "one\t0\t0\t%1\n" + "two\t2\t1\t%5\t/dev/ttys001\t100\tbash\t/home/x\n")
        check(
            mixed.count == 2,
            "L51 mixed template shapes parse (got \(mixed.count))")
        check(
            mixed[0].id == "one:0.0" && mixed[1].id == "two:2.1",
            "L51 mixed ids compose (got \(mixed.map(\.id)))")

        check(TmuxAdapter.parsePaneLines("").isEmpty, "L51 empty output -> []")
        check(
            TmuxAdapter.parsePaneLines("  \n\t\n").isEmpty,
            "L51 whitespace-only output -> []")
        check(
            TmuxAdapter.parsePaneLines("dev\t1\t2").isEmpty,
            "L51 3-field line skipped")
        check(
            TmuxAdapter.parsePaneLines("dev\t1\t2\t%12\tstray").isEmpty,
            "L51 5-field line skipped (no template shape)")
        check(
            TmuxAdapter.parsePaneLines("dev\t1\t2\t%12\ttty\tpid\tcmd").isEmpty,
            "L51 7-field line skipped (no template shape)")
        check(
            TmuxAdapter.parsePaneLines("garbage").isEmpty,
            "L51 single-field garbage skipped")
        let withBad = TmuxAdapter.parsePaneLines("ok\t0\t0\t%1\nbroken\nok2\t1\t1\t%2\n")
        check(
            withBad.count == 2,
            "L51 malformed line skipped in multi-line output (got \(withBad.count))")
        check(
            withBad.map(\.id) == ["ok:0.0", "ok2:1.1"],
            "L51 multi-line ids ordered")

        let tabbed = TmuxAdapter.parsePaneLines(
            "dev\t1\t2\t%12\t/dev/ttys003\t4242\tzsh\t/Users/me/My\tProject")
        check(
            tabbed.count == 1,
            "L51 tab-in-path line parses (got \(tabbed.count))")
        check(
            tabbed[0].id == "dev:1.2",
            "L51 tab-in-path id composes (got \(tabbed[0].id))")
        check(
            tabbed[0].currentPath == "/Users/me/My\tProject",
            "L51 tab-in-path reconstructed (got \(String(describing: tabbed[0].currentPath)))")

        let quoted = TmuxAdapter.parsePaneLines(
            "\"dev\"\t\"1\"\t\"2\"\t\"%12\"\t\"/dev/ttys003\"\t\"4242\"\t\"zsh\"\t\"/Users/me/My Project\""
        )
        check(
            quoted.count == 1 && quoted[0].id == "dev:1.2",
            "L51 quoted fields parse (got \(quoted.count))")
        check(
            quoted[0].session == "dev" && quoted[0].pid == 4242,
            "L51 quoted fields unquoted")
        check(
            quoted[0].currentPath == "/Users/me/My Project",
            "L51 quoted path with spaces kept (got \(String(describing: quoted[0].currentPath)))")

        let badPid = TmuxAdapter.parsePaneLines(
            "dev\t1\t2\t%12\t/dev/ttys003\tnan\tzsh\t/p")
        check(
            badPid.count == 1 && badPid[0].pid == nil,
            "L51 non-numeric pid decodes nil")
        check(
            badPid[0].id == "dev:1.2" && badPid[0].currentCommand == "zsh",
            "L51 non-numeric pid keeps the pane")

        // PaneInfo decodes with and without the new tmux fields.
        let legacyPaneJSON = #"{"id":"w1:p1","title":"t","cwd":"/x","workspace_id":"w1"}"#
        guard
            let legacyPane = try? JSONDecoder().decode(
                PaneInfo.self, from: Data(legacyPaneJSON.utf8))
        else {
            check(false, "L51 legacy PaneInfo decodes")
            fatalError()
        }
        check(
            legacyPane.id == "w1:p1" && legacyPane.title == "t" && legacyPane.cwd == "/x",
            "L51 legacy PaneInfo fields intact")
        check(
            legacyPane.session == nil && legacyPane.pid == nil && legacyPane.tty == nil
                && legacyPane.windowIndex == nil && legacyPane.paneIndex == nil
                && legacyPane.currentCommand == nil && legacyPane.currentPath == nil,
            "L51 legacy PaneInfo decodes without new fields")
        let fullPaneJSON =
            #"{"id":"dev:1.2","tty":"/dev/ttys003","pid":4242,"session":"dev","window_index":1,"pane_index":2,"current_command":"zsh","current_path":"/Users/me/proj"}"#
        guard
            let fullPane = try? JSONDecoder().decode(
                PaneInfo.self, from: Data(fullPaneJSON.utf8))
        else {
            check(false, "L51 full PaneInfo decodes")
            fatalError()
        }
        check(
            fullPane.pid == 4242 && fullPane.session == "dev",
            "L51 full PaneInfo decodes new fields (got pid \(String(describing: fullPane.pid)))")
        check(
            fullPane.windowIndex == 1 && fullPane.paneIndex == 2,
            "L51 full PaneInfo window/pane decode")
        check(
            fullPane.currentCommand == "zsh" && fullPane.currentPath == "/Users/me/proj",
            "L51 full PaneInfo command/path decode")

        // PATH discovery mirrors the herdr fallback-chain pattern.
        let tmuxPaths = TmuxAdapter.candidateTmuxPaths(
            env: ["PATH": "/usr/local/bin:/usr/bin"], home: "/Users/me")
        check(
            tmuxPaths == [
                "/usr/local/bin/tmux", "/usr/bin/tmux", "/opt/homebrew/bin/tmux", "/bin/tmux",
            ],
            "L51 PATH candidates in priority order (got \(tmuxPaths))")
        check(
            TmuxAdapter.candidateTmuxPaths(env: [:], home: "/Users/me").count >= 3,
            "L51 fallback chain without PATH")

        // Pane-list CLI variants: full template first, minimal fallback,
        // both pure `list-panes -a` reads that never auto-start a server.
        let tmuxVariants = TmuxAdapter.paneListCommandVariants()
        check(
            tmuxVariants.count == 2,
            "L51 two pane-list variants (got \(tmuxVariants.count))")
        check(
            tmuxVariants[0].prefix(3) == ["list-panes", "-a", "-F"],
            "L51 full variant is list-panes -a -F")
        check(
            tmuxVariants[0][3].contains("pane_tty") && tmuxVariants[0][3].contains("pane_pid")
                && tmuxVariants[0][3].contains("pane_current_command")
                && tmuxVariants[0][3].contains("pane_current_path"),
            "L51 full template carries tty/pid/command/path")
        check(
            tmuxVariants[1][3].split(separator: "\t").count == 4,
            "L51 minimal fallback template is 4 fields (got \(tmuxVariants[1][3]))")
        for variant in tmuxVariants {
            check(
                !variant.contains("new-session") && !variant.contains("start-server"),
                "L51 listing never auto-starts a server")
        }

        // Detection wiring: TmuxAdapter is selected when detection yields tmux.
        check(TmuxAdapter().kind == .tmux, "L51 TmuxAdapter kind is tmux")
        check(
            PlexerDetection.detect(env: ["TMUX": "/private/tmp/tmux-501/default,1,0"])
                == .tmux,
            "L51 TMUX env selects tmux")
        check(
            PlexerDetection.detect(env: [:], tmuxSocketExists: true) == .tmux,
            "L51 tmux socket selects tmux")
        check(
            PlexerDetection.detect(env: ["HERDR_ENV": "1", "TMUX": "/tmp/x"]) == .herdr,
            "L51 herdr wins over tmux env")
        check(
            PlexerDetection.detect(env: ["TMUX": "/tmp/stale"], tmuxSocketExists: false)
                == .tmux,
            "L51 TMUX env wins even with no socket on disk")

        // MARK: - L54. Plan 017 WI-4 — control gateway (W1 wire contract,
        // UDS NDJSON). Framing round-trip, request parsing, route table,
        // response shapes, socket path resolution.
        let multiData = Data(
            "{\"id\":\"req_1\",\"method\":\"bantay.ping\",\"params\":{}}\n{\"id\":\"req_2\",\"method\":\"agent.list\",\"params\":{}}\n"
                .utf8)
        let framed = ControlGateway.extractLines(from: multiData)
        check(framed.count == 2, "L54 multi-line NDJSON extracts 2 lines (got \(framed.count))")
        check(
            ControlGateway.parseRequest(framed[0])?.id == "req_1",
            "L54 first framed line parses with id req_1")
        check(
            ControlGateway.parseRequest(framed[1])?.method == "agent.list",
            "L54 second framed line parses with method agent.list")
        let giant = String(repeating: "x", count: 64 * 1024 + 1)
        let cappedLines = ControlGateway.extractLines(from: Data(giant.utf8))
        check(cappedLines.isEmpty, "L54 oversized line (>64 KiB) is dropped by the cap")
        let withGarbage = ControlGateway.extractLines(
            from: Data("{\"id\":\"a\",\"method\":\"bantay.ping\"}\nnot json\n".utf8))
        check(withGarbage.count == 2, "L54 garbage line still extracts as a raw line")
        check(
            ControlGateway.parseRequest(withGarbage[1]) == nil,
            "L54 garbage line fails to parse")

        let parsed = ControlGateway.parseRequest(
            "{\"id\":\"req_ab12\",\"method\":\"pane.read\",\"params\":{\"pane_id\":\"%1\",\"lines\":6}}"
        )
        check(parsed?.id == "req_ab12", "L54 parseRequest extracts id")
        check(parsed?.method == "pane.read", "L54 parseRequest extracts method")
        check(parsed?.params?["pane_id"] as? String == "%1", "L54 parseRequest keeps params dict")
        check(parsed?.params?["lines"] != nil, "L54 parseRequest keeps numeric params")
        check(ControlGateway.parseRequest("{\"id\":\"x\"}") == nil, "L54 missing method -> nil")
        check(
            ControlGateway.parseRequest("{\"method\":\"bantay.ping\"}") == nil,
            "L54 missing id -> nil")
        check(ControlGateway.parseRequest("not json at all") == nil, "L54 non-JSON line -> nil")
        check(ControlGateway.parseRequest("") == nil, "L54 empty line -> nil")
        check(
            ControlGateway.parseRequest("{\"id\":\"x\",\"method\":\"agent.list\",\"params\":[1,2]}")
                == nil,
            "L54 non-object params -> nil")

        check(
            ControlGateway.GatewayRoute.catalog.count == 6,
            "L54 catalog has 6 methods (got \(ControlGateway.GatewayRoute.catalog.count))")
        for method in ControlGateway.GatewayRoute.catalog {
            check(
                ControlGateway.route(method: method) != .unknown,
                "L54 catalog method \(method) routes non-unknown")
            check(ControlGateway.GatewayRoute.isKnown(method), "L54 \(method) is known")
        }
        check(
            ControlGateway.route(method: "bantay.frobnicate") == .unknown,
            "L54 bantay.frobnicate routes unknown")
        check(
            !ControlGateway.GatewayRoute.isKnown("bantay.frobnicate"),
            "L54 bantay.frobnicate rejected")
        check(
            ControlGateway.route(method: "bantay.ping") == .ping,
            "L54 bantay.ping maps to ping")

        let pongLine = ControlGateway.GatewayResponse.ok(
            id: "req_ab12", result: ["type": "pong", "v": 1])
        if let data = pongLine.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = obj["result"] as? [String: Any]
        {
            check(obj["id"] as? String == "req_ab12", "L54 ok response echoes request id")
            check(result["type"] as? String == "pong", "L54 ping result type is pong")
            check((result["v"] as? Int) == 1, "L54 ping result carries protocol version v")
            check(obj["error"] is NSNull, "L54 ok response has null error")
        } else {
            check(false, "L54 ok response is parseable JSON")
        }

        let errorLine = ControlGateway.GatewayResponse.error(
            id: "req_ab12", code: "unknown_method", message: "bantay.frobnicate")
        if let data = errorLine.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = obj["error"] as? [String: Any]
        {
            check(obj["id"] as? String == "req_ab12", "L54 error response echoes request id")
            check(error["code"] as? String == "unknown_method", "L54 error code is unknown_method")
            check(
                error["message"] as? String == "bantay.frobnicate", "L54 error carries method name")
            check(obj["result"] is NSNull, "L54 error response result is null")
        } else {
            check(false, "L54 error response is parseable JSON")
        }

        check(
            ControlGateway.socketPath(
                env: ["BANTAY_CONTROL_SOCKET": "/tmp/x.sock"], home: "/Users/u")
                == "/tmp/x.sock",
            "L54 BANTAY_CONTROL_SOCKET env override wins")
        check(
            ControlGateway.socketPath(env: [:], home: "/Users/u")
                == "/Users/u/Library/Application Support/Bantay-TUI/control.sock",
            "L54 default socket path under ~/Library/Application Support")
        check(
            ControlGateway.socketPath(env: ["BANTAY_CONTROL_SOCKET": ""], home: "/Users/u")
                == "/Users/u/Library/Application Support/Bantay-TUI/control.sock",
            "L54 empty env override falls back to default")

        // L56. Plan 017 WI-6 — universal hook SDK (W4): the tool
        // verification table (aider + codex verified, windsurf + cursor not),
        // per-tool hook command shapes, tool hook payload → canonical
        // AgentEventPayload mapping, non-destructive merge/remove that
        // preserves foreign hooks, idempotent double-install, and the
        // hook-emit.sh required-args contract (missing --type → exit 2)
        // mirrored as a pure function. `bash -n scripts/hook-emit.sh` is
        // asserted as a separate shell gate; this block covers the pure layer.
        do {
            let tools = HookSdk.AgentTool.allCases.map(\.rawValue)
            check(
                tools == ["aider", "codex", "windsurf", "cursor"],
                "L56 AgentTool cases are aider/codex/windsurf/cursor (got \(tools))")

            let verifyTable: [(HookSdk.AgentTool, Bool)] = [
                (.aider, true), (.codex, true), (.windsurf, false), (.cursor, false),
            ]
            for (tool, expected) in verifyTable {
                check(
                    HookSdk.isHookVerified(tool) == expected,
                    "L56 \(tool.rawValue) verified=\(expected)")
            }

            // hookCommand: verified tools return the emitter shape, unverified
            // tools return nil — a hook is never fabricated for a tool without
            // a stable hook surface.
            if let aiderCmd = HookSdk.hookCommand(for: .aider, port: 41817, token: nil) {
                check(aiderCmd.contains("hook-emit.sh"), "L56 aider command invokes the emitter")
                check(aiderCmd.contains("--source aider"), "L56 aider command tags source aider")
            } else {
                check(false, "L56 aider command is non-nil (verified mechanism)")
            }
            if let codexCmd = HookSdk.hookCommand(for: .codex, port: 41817, token: nil) {
                check(codexCmd.contains("--source codex"), "L56 codex command tags source codex")
                check(
                    codexCmd.contains("PromptStart"),
                    "L56 codex command branches on the Codex hook event")
            } else {
                check(false, "L56 codex command is non-nil (verified mechanism)")
            }
            check(
                HookSdk.hookCommand(for: .windsurf, port: 41817, token: nil) == nil,
                "L56 windsurf has no hook command (unverified surface)")
            check(
                HookSdk.hookCommand(for: .cursor, port: 41817, token: nil) == nil,
                "L56 cursor has no hook command (unverified surface)")
            if let tokenCmd = HookSdk.hookCommand(for: .codex, port: 41817, token: "abc123") {
                check(
                    tokenCmd.contains("BANTAY_INGEST_TOKEN=abc123"),
                    "L56 explicit token is embedded in the hook command")
            } else {
                check(false, "L56 tokenized codex command is non-nil")
            }

            // mapToEventPayload: canned tool payloads → canonical shape.
            let codexStart: [String: Any] = [
                "event_type": "PromptStart", "prompt": "run tests", "model": "gpt-5",
            ]
            let codexStartMapped = HookSdk.mapToEventPayload(codexStart, tool: .codex)
            check(
                codexStartMapped?["source"] as? String == "codex"
                    && codexStartMapped?["type"] as? String == "progress",
                "L56 codex PromptStart maps to codex/progress")
            check(
                codexStartMapped?["title"] as? String == "run tests",
                "L56 codex PromptStart keeps the prompt as title")
            let codexDone: [String: Any] = [
                "event_type": "PromptFinish", "result": "success", "prompt": "run tests",
            ]
            check(
                HookSdk.mapToEventPayload(codexDone, tool: .codex)?["type"] as? String
                    == "completed",
                "L56 codex PromptFinish success maps to completed")
            let codexFailed: [String: Any] = [
                "event_type": "PromptFinish", "result": "error", "prompt": "run tests",
            ]
            check(
                HookSdk.mapToEventPayload(codexFailed, tool: .codex)?["type"] as? String
                    == "failed",
                "L56 codex PromptFinish error maps to failed")
            check(
                HookSdk.mapToEventPayload(["event_type": "PromptPlan"], tool: .codex) == nil,
                "L56 codex PromptPlan is not an actionable event")
            check(
                HookSdk.mapToEventPayload(["something": "else"], tool: .codex) == nil,
                "L56 codex payload without event_type maps nil")

            let aiderEdit: [String: Any] = [
                "event": "post-edit", "path": "Sources/BantayTUI/HookSdk.swift",
            ]
            let aiderMapped = HookSdk.mapToEventPayload(aiderEdit, tool: .aider)
            check(
                aiderMapped?["source"] as? String == "aider"
                    && aiderMapped?["type"] as? String == "progress",
                "L56 aider post-edit maps to aider/progress")
            check(
                aiderMapped?["title"] as? String == "Sources/BantayTUI/HookSdk.swift",
                "L56 aider post-edit keeps the edited path as title")
            check(
                HookSdk.mapToEventPayload(["event": "post-commit"], tool: .aider)?["type"]
                    as? String == "completed",
                "L56 aider post-commit maps to completed")
            check(
                HookSdk.mapToEventPayload(["event": "frobnicate"], tool: .aider) == nil,
                "L56 aider unknown event maps nil")

            // Canonical payload round-trips through the exact decoder the UDS
            // ingest uses (AgentEventPayload) — the emitted line is ingestible.
            if let mapped = HookSdk.mapToEventPayload(codexStart, tool: .codex),
                let data = try? JSONSerialization.data(withJSONObject: mapped),
                let decoded = try? JSONDecoder().decode(AgentEventPayload.self, from: data)
            {
                check(decoded.source == "codex", "L56 canonical payload decodes with source codex")
            } else {
                check(false, "L56 canonical payload round-trips through AgentEventPayload")
            }

            // mergeHooks: preserves foreign keys, idempotent double-install,
            // never fabricates hooks for unverified tools.
            let foreignConfig: [String: Any] = [
                "model": "gpt-5",
                "hooks": [
                    "PromptStart": [
                        "command": ["sh", "-lc", "my-foreign --notify"]
                    ],
                    "SessionStart": [
                        "command": ["sh", "-lc", "echo session"]
                    ],
                ],
            ]
            let mergedOnce = HookSdk.mergeHooks(
                existing: foreignConfig, tool: .codex, port: 41817)
            check(
                mergedOnce["model"] as? String == "gpt-5",
                "L56 merge preserves foreign top-level keys")
            let mergedHooks = mergedOnce["hooks"] as? [String: Any]
            check(
                mergedHooks?["SessionStart"] != nil,
                "L56 merge preserves foreign hook events untouched")
            let foreignStart =
                (mergedHooks?["PromptStart"] as? [String: Any])?["command"]
                as? [String]
            check(
                foreignStart?.last == "my-foreign --notify",
                "L56 merge never clobbers a foreign command for an owned event")
            check(
                mergedHooks?["PromptFinish"] != nil,
                "L56 merge adds Bantay's hook for an unclaimed event")
            let mergedTwice = HookSdk.mergeHooks(
                existing: mergedOnce, tool: .codex, port: 41817)
            check(
                NSDictionary(dictionary: mergedOnce).isEqual(to: mergedTwice),
                "L56 double merge is idempotent (no duplicate install)")
            let stringHooks: [String: Any] = ["hooks": "not a dict"]
            check(
                NSDictionary(
                    dictionary: HookSdk.mergeHooks(
                        existing: stringHooks, tool: .codex, port: 41817)
                ).isEqual(
                    to: NSDictionary(dictionary: stringHooks)),
                "L56 non-dict hooks value is returned unchanged")
            check(
                NSDictionary(
                    dictionary: HookSdk.mergeHooks(
                        existing: foreignConfig, tool: .windsurf, port: 41817)
                ).isEqual(
                    to: NSDictionary(dictionary: foreignConfig)),
                "L56 merge never fabricates hooks for an unverified tool")

            // removingHooks: drops only Bantay-owned hooks, never foreign ones,
            // and never touches an unverified tool's config.
            let bantayConfig: [String: Any] = [
                "hooks": [
                    "PromptStart": [
                        "command": [
                            "sh", "-lc",
                            "scripts/hook-emit.sh --source codex --type progress",
                        ]
                    ],
                    "PromptFinish": [
                        "command": [
                            "sh", "-lc",
                            "scripts/hook-emit.sh --source codex --type completed",
                        ]
                    ],
                    "SessionStart": [
                        "command": ["sh", "-lc", "echo foreign"]
                    ],
                ]
            ]
            let removed = HookSdk.removingHooks(from: bantayConfig, tool: .codex)
            let removedHooks = removed["hooks"] as? [String: Any]
            check(
                removedHooks?["PromptStart"] == nil && removedHooks?["PromptFinish"] == nil,
                "L56 removal drops only Bantay's owned events")
            check(
                removedHooks?["SessionStart"] != nil,
                "L56 removal preserves foreign hook events")
            let fullyOwned: [String: Any] = [
                "hooks": [
                    "PromptStart": [
                        "command": [
                            "sh", "-lc",
                            "scripts/hook-emit.sh --source codex --type progress",
                        ]
                    ]
                ]
            ]
            let removedAll = HookSdk.removingHooks(from: fullyOwned, tool: .codex)
            check(
                removedAll["hooks"] == nil,
                "L56 removal drops the hooks key when no hooks remain")
            check(
                NSDictionary(
                    dictionary: HookSdk.removingHooks(
                        from: bantayConfig, tool: .windsurf)
                ).isEqual(
                    to: NSDictionary(dictionary: bantayConfig)),
                "L56 removal never touches an unverified tool's config")

            // hook-emit.sh required-args contract, mirrored in Swift: a
            // missing --type/--source/--title (or a value-less flag) exits 2;
            // a complete invocation exits 0. The shell gate runs
            // `bash -n scripts/hook-emit.sh` separately.
            check(
                HookSdk.emitterExitCodeFor(args: ["--source", "codex"]) == 2,
                "L56 missing --type exits 2")
            check(
                HookSdk.emitterExitCodeFor(args: ["--type"]) == 2,
                "L56 --type without a value exits 2")
            check(
                HookSdk.emitterExitCodeFor(args: ["--type", "progress"]) == 2,
                "L56 missing --source exits 2")
            check(
                HookSdk.emitterExitCodeFor(
                    args: ["--source", "codex", "--type", "progress", "--title", "t"]) == 0,
                "L56 complete invocation exits 0")
        }

        // MARK: - L53. Plan 017 WI-3 — process-level pane tracking & focus
        // routing: the pure PaneFocusRouter maps a composed paneId to the
        // multiplexer command that selects the pane plus the terminal
        // activation strategy. Covers per-kind id parsing, the drift
        // fallback (tty/pid re-key after a mux restart regenerates pane
        // ids), the focus-command shapes, the route() table, and the
        // pid-reuse guard.
        // resolveTarget parses the composed paneId per kind.
        check(
            PaneFocusRouter.resolveTarget(paneId: "dev:1.2", kind: .tmux)
                == .tmux(session: "dev", window: "1", pane: "2"),
            "L53 tmux paneId resolves to (session, window, pane)")
        check(
            PaneFocusRouter.resolveTarget(paneId: "dev|pane3", kind: .zellij)
                == .zellij(session: "dev", pane: "pane3"),
            "L53 zellij paneId resolves to (session, pane)")
        check(
            PaneFocusRouter.resolveTarget(paneId: "pane_abc123", kind: .herdr)
                == .herdr(paneId: "pane_abc123"),
            "L53 herdr paneId passes through raw")
        check(
            PaneFocusRouter.resolveTarget(paneId: "  pane_abc123  ", kind: .herdr)
                == .herdr(paneId: "pane_abc123"),
            "L53 herdr paneId trimmed")
        check(
            PaneFocusRouter.resolveTarget(paneId: "no-separator", kind: .tmux) == .none,
            "L53 malformed tmux paneId -> none")
        check(
            PaneFocusRouter.resolveTarget(paneId: "dev:1", kind: .tmux) == .none,
            "L53 tmux paneId missing window.pane -> none")
        check(
            PaneFocusRouter.resolveTarget(paneId: "dev:1.2.3", kind: .tmux) == .none,
            "L53 tmux paneId with extra dot -> none")
        check(
            PaneFocusRouter.resolveTarget(paneId: "pane3", kind: .zellij) == .none,
            "L53 malformed zellij paneId -> none")
        check(
            PaneFocusRouter.resolveTarget(paneId: "", kind: .herdr) == .none,
            "L53 empty herdr paneId -> none")

        // Drift fallback: pane ids regenerate on mux restart, so re-key by
        // tty (strongest) then pid against the current pane list.
        let restartedPanes = [
            PaneInfo(
                id: "dev:0.0", title: nil, cwd: nil, workspaceId: nil, tty: "/dev/ttys003",
                pid: 4242),
            PaneInfo(
                id: "dev:1.1", title: nil, cwd: nil, workspaceId: nil, tty: "/dev/ttys001",
                pid: 1111),
        ]
        check(
            PaneFocusRouter.resolveByTty(tty: "/dev/ttys003", panes: restartedPanes) == "dev:0.0",
            "L53 tty re-keys to the regenerated pane id")
        check(
            PaneFocusRouter.resolveByPid(pid: 1111, panes: restartedPanes) == "dev:1.1",
            "L53 pid re-keys to the regenerated pane id")
        check(
            PaneFocusRouter.resolveByTty(tty: "/dev/ttys999", panes: restartedPanes) == nil,
            "L53 unknown tty -> nil")
        check(
            PaneFocusRouter.resolveByPid(pid: 9999, panes: restartedPanes) == nil,
            "L53 unknown pid -> nil")
        check(
            PaneFocusRouter.resolveByTty(tty: "", panes: restartedPanes) == nil,
            "L53 empty tty -> nil")
        check(
            PaneFocusRouter.resolveByPid(pid: 0, panes: restartedPanes) == nil,
            "L53 zero pid -> nil")
        // resolveDrifted: a stale id that still exists wins verbatim.
        check(
            PaneFocusRouter.resolveDrifted(
                stalePaneId: "dev:1.1", tty: "/dev/ttys001", pid: 1111,
                panes: restartedPanes) == "dev:1.1",
            "L53 live id survives drift resolution")
        // A vanished pane id re-keys via tty.
        check(
            PaneFocusRouter.resolveDrifted(
                stalePaneId: "old:9.9", tty: "/dev/ttys003", pid: 4242,
                panes: restartedPanes) == "dev:0.0",
            "L53 vanished id re-keys via tty")
        // Pid-reuse guard: the pid now belongs to a DIFFERENT pane than the
        // tty does — the tty match must win.
        let reusedPidPanes = [
            PaneInfo(
                id: "new:0.0", title: nil, cwd: nil, workspaceId: nil, tty: "/dev/ttys003",
                pid: 7777),
            PaneInfo(
                id: "new:1.0", title: nil, cwd: nil, workspaceId: nil, tty: "/dev/ttys001",
                pid: 4242),
        ]
        check(
            PaneFocusRouter.resolveDrifted(
                stalePaneId: "old:0.0", tty: "/dev/ttys003", pid: 4242,
                panes: reusedPidPanes) == "new:0.0",
            "L53 pid-reuse guard prefers the tty match")
        check(
            PaneFocusRouter.resolveDrifted(
                stalePaneId: "old:0.0", tty: nil, pid: 4242, panes: reusedPidPanes)
                == "new:1.0",
            "L53 pid-only re-key still resolves without tty evidence")
        check(
            PaneFocusRouter.resolveDrifted(
                stalePaneId: "old:0.0", tty: nil, pid: nil, panes: reusedPidPanes) == nil,
            "L53 no tty/pid evidence -> nil")
        // resolveForFocus: kind nil means no mux -> standalone (terminal only).
        check(
            PaneFocusRouter.resolveForFocus(
                paneId: "dev:1.2", kind: nil, tty: nil, pid: nil, panes: []) == .standalone,
            "L53 no mux resolves standalone")
        check(
            PaneFocusRouter.resolveForFocus(
                paneId: "dev:1.2", kind: .tmux, tty: nil, pid: nil, panes: [])
                == .tmux(session: "dev", window: "1", pane: "2"),
            "L53 tmux resolves directly through resolveForFocus")
        check(
            PaneFocusRouter.resolveForFocus(
                paneId: "old:9.9", kind: .tmux, tty: "/dev/ttys003", pid: 4242,
                panes: restartedPanes) == .tmux(session: "dev", window: "0", pane: "0"),
            "L53 drift re-keys through resolveForFocus")
        check(
            PaneFocusRouter.resolveForFocus(
                paneId: "old:9.9", kind: .tmux, tty: nil, pid: nil, panes: restartedPanes)
                == .none,
            "L53 unresolvable drift -> none")

        // focusCommand shapes per kind.
        check(
            PaneFocusRouter.focusCommand(target: .tmux(session: "dev", window: "1", pane: "2"))
                == ["tmux", "select-pane", "-t", "dev:1.2", ";", "switch-client", "-t", "dev"],
            "L53 tmux focus command selects pane then switches client")
        check(
            PaneFocusRouter.focusCommand(target: .zellij(session: "dev", pane: "pane3"))
                == ["zellij", "--session", "dev", "action", "focus-pane-id", "pane3"],
            "L53 zellij focus command is the 0.40+ focus-pane-id verb")
        check(
            PaneFocusRouter.focusCommand(target: .herdr(paneId: "pane_abc123"))
                == ["herdr", "agent", "focus", "pane_abc123"],
            "L53 herdr focus command is the agent focus verb")
        check(
            PaneFocusRouter.focusCommand(target: .standalone) == nil,
            "L53 standalone has no mux focus command")
        check(
            PaneFocusRouter.focusCommand(target: .none) == nil,
            "L53 none has no focus command")

        // route() table: mux -> both (mux select + terminal activation),
        // standalone -> terminal only, none -> nothing.
        check(
            PaneFocusRouter.route(target: .tmux(session: "dev", window: "1", pane: "2"))
                == .both,
            "L53 tmux routes to both")
        check(
            PaneFocusRouter.route(target: .zellij(session: "dev", pane: "pane3")) == .both,
            "L53 zellij routes to both")
        check(
            PaneFocusRouter.route(target: .herdr(paneId: "pane_abc123")) == .both,
            "L53 herdr routes to both")
        check(
            PaneFocusRouter.route(target: .standalone) == .terminalOnly,
            "L53 standalone routes to terminal only")
        check(
            PaneFocusRouter.route(target: .none) == .none,
            "L53 none routes to nothing")

        // L57. Performance sweep (PERF-1/PERF-2): pure decisions for caching
        // projectContext (parse .git/HEAD without disk I/O in the render path),
        // throttling the standalone ps scan, and skipping unchanged transcript
        // re-reads by mtime.
        do {
            let mainBranch = ProjectContext.parseHead(
                "ref: refs/heads/main\n")
            check(
                mainBranch.branch == "main" && mainBranch.isGit,
                "L57 parseHead ref: refs/heads/main -> main, git (got \(mainBranch))")
            let detached = ProjectContext.parseHead(
                "9f8a2b4c5d6e7f8090a1b2c3d4e5f60718293a4b5\n")
            check(
                detached.branch == "detached" && detached.isGit,
                "L57 parseHead hex -> detached, git")
            let empty = ProjectContext.parseHead("")
            check(empty.branch == nil && !empty.isGit, "L57 parseHead empty -> not git")
            let packed = ProjectContext.parseHead("ref: refs/heads/feat/016-perf\n")
            check(
                packed.branch == "feat/016-perf",
                "L57 parseHead nested branch path (got \(String(describing: packed.branch)))")

            let now = Date()
            let recent = now.addingTimeInterval(-1)
            let stale = now.addingTimeInterval(-31)
            check(
                StandaloneAgentScanner.shouldRescan(
                    lastScan: stale, now: now, minInterval: 30),
                "L57 scan throttled: 31s ago -> rescan")
            check(
                !StandaloneAgentScanner.shouldRescan(
                    lastScan: recent, now: now, minInterval: 30),
                "L57 scan throttled: 1s ago -> skip")
            check(
                StandaloneAgentScanner.shouldRescan(
                    lastScan: nil, now: now, minInterval: 30),
                "L57 scan throttled: never scanned -> rescan")

            let projects = StandaloneAgentScanner.projectRoots("")
            check(projects == [], "L57 projectRoots(empty) -> []")
        }

        // L58. Notch animation sync (fix 016): the content cross-fade must be
        // coordinated with the background morph so text never pops before the
        // notch finishes morphing. Full motion -> synced opacity+scale;
        // reduce motion -> instant opacity-only, matching the morph style.
        check(
            IslandMetrics.contentTransition(reduceMotion: false) == .synced,
            "L58 full motion syncs content with the morph")
        check(
            IslandMetrics.contentTransition(reduceMotion: true) == .instant,
            "L58 reduced motion snaps content instantly")
        check(
            IslandMetrics.morphMatchesContent(reduceMotion: false),
            "L58 content + morph both smooth without reduceMotion")
        check(
            IslandMetrics.morphMatchesContent(reduceMotion: true),
            "L58 content + morph both near-instant with reduceMotion")

        // L59. Push-stream wire contract (herdr events.subscribe). The stream
        // parses pane records into HerdrStreamPane; fromJSON is the pure
        // decode the whole real-time roster depends on. Pin the exact field
        // mapping the live socket emits (verified: underscore event names like
        // pane_updated, snake_case payload keys).
        let streamPane = HerdrStreamPane.fromJSON([
            "pane_id": "w3:p3",
            "agent": "kilo",
            "agent_status": "blocked",
            "cwd": "/Users/me/proj",
            "workspace_id": "w3",
            "terminal_title_stripped": "Kilo CLI",
            "focused": true,
        ])
        check(streamPane != nil, "L59 fromJSON parses a full pane record")
        check(streamPane?.paneId == "w3:p3", "L59 pane_id mapped")
        check(streamPane?.agent == "kilo", "L59 agent mapped")
        check(streamPane?.agentStatus == "blocked", "L59 agent_status mapped")
        check(streamPane?.cwd == "/Users/me/proj", "L59 cwd mapped")
        check(streamPane?.workspaceId == "w3", "L59 workspace_id mapped")
        check(streamPane?.terminalTitle == "Kilo CLI", "L59 title_stripped preferred")
        check(streamPane?.focused == true, "L59 focused mapped")
        let fallbackTitle = HerdrStreamPane.fromJSON([
            "pane_id": "w3:p4",
            "terminal_title": "codex | working",
        ])
        check(
            fallbackTitle?.terminalTitle == "codex | working",
            "L59 terminal_title fallback when stripped absent")
        check(
            HerdrStreamPane.fromJSON(["agent": "no-pane-id"]) == nil,
            "L59 record without pane_id rejected")

        // L60. ntfy payload builder — the push body/priority contract. Empty
        // topic disables; known kinds get the right text + urgency mapping.
        check(
            AgentAlertNotifier.messageBody(
                source: "codex", kind: .accessRequest, title: "run tests"
            ) == "codex needs your approval: run tests",
            "L60 accessRequest body")
        check(
            AgentAlertNotifier.messageBody(source: "kilo", kind: .failed, title: nil)
                == "kilo failed",
            "L60 failed body without title")
        check(
            AgentAlertNotifier.messageBody(source: "claude", kind: .completed, title: "done")
                == "claude finished: done",
            "L60 completed body")
        // Redaction: home paths are stripped, long titles truncated.
        let home = NSHomeDirectory()
        let long = String(repeating: "x", count: 300)
        let redacted = AgentAlertNotifier.redactedTitle("\(home)/proj/some long title \(long)")
        check(
            !(redacted ?? "").contains(home) && (redacted ?? "").hasSuffix("…"),
            "L60 redacts home path and truncates long titles")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)

    }
}
