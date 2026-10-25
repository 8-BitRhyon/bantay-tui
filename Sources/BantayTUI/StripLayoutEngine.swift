import Foundation

/// Status of an AI coding agent or worker in a strip window.
public enum StripAgentStatus: String, Equatable, Sendable, CaseIterable {
    case idle
    case working
    case needsApproval
    case completed
    case failed

    init(eventKind: AgentEventKind?) {
        guard let eventKind else {
            self = .idle
            return
        }
        switch eventKind {
        case .accessRequest, .waiting:
            self = .needsApproval
        case .started, .progress:
            self = .working
        case .completed:
            self = .completed
        case .failed, .cancelled:
            self = .failed
        case .idle, .clear:
            self = .idle
        }
    }
}

/// A pure rectangle structure with floating point geometry for cross-platform layout logic.
public struct StripRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2.0 }
    public var midY: Double { y + height / 2.0 }
}

/// Metadata and state for a single window managed by the Strip canvas.
public struct StripWindowInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public var pid: Int32
    public var appBundleID: String
    public var title: String
    public var agentName: String?
    public var agentCwd: String?
    public var agentStatus: StripAgentStatus
    /// Window height when first discovered. Zero means unknown.
    public var originalHeight: Double

    public init(
        id: String,
        pid: Int32 = 0,
        appBundleID: String = "",
        title: String = "",
        agentName: String? = nil,
        agentCwd: String? = nil,
        agentStatus: StripAgentStatus = .idle,
        originalHeight: Double = 0
    ) {
        self.id = id
        self.pid = pid
        self.appBundleID = appBundleID
        self.title = title
        self.agentName = agentName
        self.agentCwd = agentCwd
        self.agentStatus = agentStatus
        self.originalHeight = originalHeight
    }
}

/// A vertical column on the horizontal strip that hosts one or more windows.
public struct StripColumn: Equatable, Sendable, Identifiable {
    public let id: String
    public var windows: [StripWindowInfo]
    public var widthFraction: Double
    public var isTabbed: Bool
    public var focusedRow: Int
    public var isPinned: Bool
    public var savedFraction: Double?

    public init(
        id: String = UUID().uuidString,
        windows: [StripWindowInfo] = [],
        widthFraction: Double = 0.5,
        isTabbed: Bool = false,
        focusedRow: Int = 0,
        isPinned: Bool = false,
        savedFraction: Double? = nil
    ) {
        self.id = id
        self.windows = windows
        self.widthFraction = widthFraction
        self.isTabbed = isTabbed
        self.focusedRow = focusedRow
        self.isPinned = isPinned
        self.savedFraction = savedFraction
    }

    public var activeWindow: StripWindowInfo? {
        guard !windows.isEmpty else { return nil }
        let idx = max(0, min(focusedRow, windows.count - 1))
        return windows[idx]
    }
}

/// Geometric bounds, margins, and scroll position of the active display canvas.
public struct StripViewport: Equatable, Sendable {
    public var screenOriginX: Double
    public var screenOriginY: Double
    public var screenWidth: Double
    public var screenHeight: Double
    public var gap: Double
    public var inset: Double
    public var scrollOffset: Double

    public init(
        screenOriginX: Double = 0.0,
        screenOriginY: Double = 0.0,
        screenWidth: Double = 1710.0,
        screenHeight: Double = 1000.0,
        gap: Double = 12.0,
        inset: Double = 12.0,
        scrollOffset: Double = 0.0
    ) {
        self.screenOriginX = screenOriginX
        self.screenOriginY = screenOriginY
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.gap = gap
        self.inset = inset
        self.scrollOffset = scrollOffset
    }

    public var availableWidth: Double {
        max(100.0, screenWidth - inset * 2.0)
    }

    public var availableHeight: Double {
        max(100.0, screenHeight - inset * 2.0)
    }
}

/// Physical spring simulation for interruptible, silky-smooth viewport and window transitions.
public struct DampedSpring: Equatable, Sendable {
    public var x: Double
    public var v: Double
    public var target: Double

    public init(initialValue: Double = 0.0) {
        self.x = initialValue
        self.v = 0.0
        self.target = initialValue
    }

    @discardableResult
    public mutating func step(dt: Double, omega: Double = 13.0) -> Bool {
        if x == target && v == 0.0 { return false }
        let d = x - target
        let expTerm = exp(-omega * dt)
        let a = (v + omega * d) * dt
        x = target + (d + a) * expTerm
        v = (v - (v + omega * d) * omega * dt) * expTerm
        if abs(x - target) < 0.06 && abs(v) < 0.6 {
            x = target
            v = 0.0
        }
        return true
    }

    public mutating func snap() {
        x = target
        v = 0.0
    }

    /// Asymptotic rubberbanding when dragging or scrolling past boundaries.
    public static func rubberBand(
        offset: Double,
        maxOffset: Double,
        screenWidth: Double
    ) -> Double {
        let dim = max(1.0, screenWidth * 0.5)
        let calc: (Double) -> Double = { o in
            (1.0 - 1.0 / (o * 0.55 / dim + 1.0)) * dim
        }
        if offset < 0.0 {
            return -calc(-offset)
        } else if offset > maxOffset {
            return maxOffset + calc(offset - maxOffset)
        }
        return offset
    }
}

/// The computed placement of every column and window on the display canvas.
public struct StripLayoutResult: Equatable, Sendable {
    public var columnFrames: [StripRect]
    public var windowFrames: [String: StripRect]
    public var totalStripWidth: Double
    public var maxScrollOffset: Double
    public var visibleWindowIDs: Set<String>
    public var offscreenLeftIDs: Set<String>
    public var offscreenRightIDs: Set<String>

    public init(
        columnFrames: [StripRect] = [],
        windowFrames: [String: StripRect] = [:],
        totalStripWidth: Double = 0.0,
        maxScrollOffset: Double = 0.0,
        visibleWindowIDs: Set<String> = [],
        offscreenLeftIDs: Set<String> = [],
        offscreenRightIDs: Set<String> = []
    ) {
        self.columnFrames = columnFrames
        self.windowFrames = windowFrames
        self.totalStripWidth = totalStripWidth
        self.maxScrollOffset = maxScrollOffset
        self.visibleWindowIDs = visibleWindowIDs
        self.offscreenLeftIDs = offscreenLeftIDs
        self.offscreenRightIDs = offscreenRightIDs
    }
}

/// Pure mathematical layout calculations for the infinite scrolling agent strip.
public enum StripLayoutEngine {
    /// Standard preset fractions when cycling window widths (⌃⌥R).
    public static let defaultWidthPresets: [Double] = [0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75, 1.0]

    /// Computes exact screen coordinates for all columns and windows.
    public static func computeLayout(
        columns: [StripColumn],
        viewport: StripViewport,
        keepOriginalHeight: Bool = false
    ) -> StripLayoutResult {
        guard !columns.isEmpty else {
            return StripLayoutResult()
        }

        var colFrames: [StripRect] = []
        var winFrames: [String: StripRect] = [:]
        var visibleIDs = Set<String>()
        var leftIDs = Set<String>()
        var rightIDs = Set<String>()

        let availW = viewport.availableWidth
        let availH = viewport.availableHeight
        let gap = viewport.gap
        let inset = viewport.inset

        let pinnedColIndex = columns.firstIndex(where: { $0.isPinned })
        let pinnedW =
            pinnedColIndex.map {
                max(120.0, round(columns[$0].widthFraction * (availW + gap) - gap))
            } ?? 0.0

        let scrollAreaOriginX =
            (pinnedColIndex != nil)
            ? viewport.screenOriginX + inset + pinnedW + gap
            : viewport.screenOriginX
        let scrollAvailW =
            (pinnedColIndex != nil)
            ? max(120.0, availW - pinnedW - gap)
            : availW

        var scrollViewport = viewport
        if pinnedColIndex != nil {
            scrollViewport.screenOriginX = scrollAreaOriginX
            scrollViewport.screenWidth = scrollAvailW
        }

        var unpinnedStripX = (pinnedColIndex != nil) ? 0.0 : inset

        for col in columns {
            if col.isPinned {
                let colScreenX = viewport.screenOriginX + inset
                let colScreenY = viewport.screenOriginY + inset
                let colFrame = StripRect(
                    x: colScreenX,
                    y: colScreenY,
                    width: pinnedW,
                    height: availH
                )
                colFrames.append(colFrame)

                let winCount = col.windows.count
                if winCount == 1 {
                    let win = col.windows[0]
                    winFrames[win.id] = singleWindowFrame(
                        colFrame, window: win, keepOriginalHeight: keepOriginalHeight)
                    visibleIDs.insert(win.id)
                } else if winCount > 1 {
                    if col.isTabbed {
                        let tabH = 24.0
                        let bodyH = max(80.0, availH - tabH)
                        let bodyY = colScreenY + tabH
                        for win in col.windows {
                            let winFrame = StripRect(
                                x: colScreenX,
                                y: bodyY,
                                width: pinnedW,
                                height: bodyH
                            )
                            winFrames[win.id] = winFrame
                            visibleIDs.insert(win.id)
                        }
                    } else {
                        let totalGaps = Double(winCount - 1) * gap
                        let winH = max(60.0, (availH - totalGaps) / Double(winCount))
                        for (wIdx, win) in col.windows.enumerated() {
                            let winY = colScreenY + Double(wIdx) * (winH + gap)
                            let winFrame = StripRect(
                                x: colScreenX,
                                y: winY,
                                width: pinnedW,
                                height: winH
                            )
                            winFrames[win.id] = winFrame
                            visibleIDs.insert(win.id)
                        }
                    }
                }
            } else {
                let colW = max(120.0, round(col.widthFraction * (scrollAvailW + gap) - gap))
                let colScreenX = scrollAreaOriginX + unpinnedStripX - viewport.scrollOffset
                let colScreenY = viewport.screenOriginY + inset

                let colFrame = StripRect(
                    x: colScreenX,
                    y: colScreenY,
                    width: colW,
                    height: availH
                )
                colFrames.append(colFrame)

                let winCount = col.windows.count
                if winCount == 1 {
                    let win = col.windows[0]
                    let frame = singleWindowFrame(
                        colFrame, window: win, keepOriginalHeight: keepOriginalHeight)
                    winFrames[win.id] = frame
                    classifyVisibility(
                        frame: frame,
                        id: win.id,
                        viewport: scrollViewport,
                        visibleIDs: &visibleIDs,
                        leftIDs: &leftIDs,
                        rightIDs: &rightIDs
                    )
                } else if winCount > 1 {
                    if col.isTabbed {
                        let tabH = 24.0
                        let bodyH = max(80.0, availH - tabH)
                        let bodyY = colScreenY + tabH
                        for (idx, win) in col.windows.enumerated() {
                            let winFrame = StripRect(
                                x: colScreenX,
                                y: bodyY,
                                width: colW,
                                height: bodyH
                            )
                            winFrames[win.id] = winFrame
                            if idx == col.focusedRow {
                                classifyVisibility(
                                    frame: winFrame,
                                    id: win.id,
                                    viewport: scrollViewport,
                                    visibleIDs: &visibleIDs,
                                    leftIDs: &leftIDs,
                                    rightIDs: &rightIDs
                                )
                            }
                        }
                    } else {
                        let totalGaps = Double(winCount - 1) * gap
                        let winH = max(60.0, (availH - totalGaps) / Double(winCount))
                        for (idx, win) in col.windows.enumerated() {
                            let winY = colScreenY + Double(idx) * (winH + gap)
                            let winFrame = StripRect(
                                x: colScreenX,
                                y: winY,
                                width: colW,
                                height: winH
                            )
                            winFrames[win.id] = winFrame
                            classifyVisibility(
                                frame: winFrame,
                                id: win.id,
                                viewport: scrollViewport,
                                visibleIDs: &visibleIDs,
                                leftIDs: &leftIDs,
                                rightIDs: &rightIDs
                            )
                        }
                    }
                }

                unpinnedStripX += colW + gap
            }
        }

        let totalStripWidth: Double
        let maxScroll: Double
        if pinnedColIndex != nil {
            let unpinnedContentWidth = max(0.0, unpinnedStripX - gap)
            totalStripWidth = pinnedW + gap + unpinnedContentWidth + (2.0 * inset)
            maxScroll = max(0.0, unpinnedContentWidth - scrollAvailW)
        } else {
            totalStripWidth = unpinnedStripX - gap + inset
            maxScroll = max(0.0, totalStripWidth - viewport.screenWidth)
        }

        return StripLayoutResult(
            columnFrames: colFrames,
            windowFrames: winFrames,
            totalStripWidth: totalStripWidth,
            maxScrollOffset: maxScroll,
            visibleWindowIDs: visibleIDs,
            offscreenLeftIDs: leftIDs,
            offscreenRightIDs: rightIDs
        )
    }

    /// Native window tabs share one geometry and expose AXTabs. Keeping all
    /// of them would put one column on the strip per tab. Returns the ids to
    /// drop: for each shared geometry group that has tabs, all but the first.
    public static func collapsedNativeTabIDs(
        _ windows: [(id: String, frameKey: String, hasTabs: Bool)]
    ) -> Set<String> {
        let groups = Dictionary(grouping: windows, by: \.frameKey)
        var dropped = Set<String>()
        for (_, group) in groups where group.count > 1 {
            guard group.contains(where: \.hasTabs) else { continue }
            for window in group.dropFirst() { dropped.insert(window.id) }
        }
        return dropped
    }

    /// A single window fills its column by default. With keep-original-height
    /// it keeps the height it opened with, clamped to the column, aligned to
    /// the top.
    static func singleWindowFrame(
        _ columnFrame: StripRect,
        window: StripWindowInfo,
        keepOriginalHeight: Bool
    ) -> StripRect {
        guard keepOriginalHeight, window.originalHeight > 0 else { return columnFrame }
        let height = min(max(window.originalHeight, 120.0), columnFrame.height)
        return StripRect(
            x: columnFrame.x,
            y: columnFrame.y,
            width: columnFrame.width,
            height: height)
    }

    private static func classifyVisibility(
        frame: StripRect,
        id: String,
        viewport: StripViewport,
        visibleIDs: inout Set<String>,
        leftIDs: inout Set<String>,
        rightIDs: inout Set<String>
    ) {
        let screenLeft = viewport.screenOriginX
        let screenRight = viewport.screenOriginX + viewport.screenWidth

        if frame.maxX < screenLeft {
            leftIDs.insert(id)
        } else if frame.x > screenRight {
            rightIDs.insert(id)
        } else {
            visibleIDs.insert(id)
        }
    }

    /// Computes the scroll offset target that reveals the given column with margins.
    public static func revealTarget(
        columnIndex: Int,
        columns: [StripColumn],
        viewport: StripViewport
    ) -> Double {
        guard columnIndex >= 0 && columnIndex < columns.count else {
            return viewport.scrollOffset
        }

        if columns[columnIndex].isPinned {
            return 0.0
        }

        let availW = viewport.availableWidth
        let gap = viewport.gap
        let inset = viewport.inset

        let pinnedColIndex = columns.firstIndex(where: { $0.isPinned })
        let pinnedW =
            pinnedColIndex.map {
                max(120.0, round(columns[$0].widthFraction * (availW + gap) - gap))
            } ?? 0.0
        let scrollAvailW =
            (pinnedColIndex != nil)
            ? max(120.0, availW - pinnedW - gap)
            : availW

        var stripX = (pinnedColIndex != nil) ? 0.0 : inset
        for i in 0..<columnIndex {
            if !columns[i].isPinned {
                let w = max(120.0, round(columns[i].widthFraction * (scrollAvailW + gap) - gap))
                stripX += w + gap
            }
        }
        let targetW = max(
            120.0,
            round(columns[columnIndex].widthFraction * (scrollAvailW + gap) - gap)
        )

        let colStripLeft = stripX
        let colStripRight = stripX + targetW

        let layout = computeLayout(columns: columns, viewport: viewport)
        let maxScroll = layout.maxScrollOffset

        var currentScroll = viewport.scrollOffset
        let leftBound = colStripLeft - gap
        let rightBound = colStripRight + gap

        let effectiveScreenWidth = (pinnedColIndex != nil) ? scrollAvailW : viewport.screenWidth

        if leftBound < currentScroll {
            currentScroll = leftBound
        } else if rightBound > currentScroll + effectiveScreenWidth {
            currentScroll = rightBound - effectiveScreenWidth
        }

        return max(0.0, min(currentScroll, maxScroll))
    }

    /// Computes the scroll offset target that places the given column in the center of the display.
    public static func centerTarget(
        columnIndex: Int,
        columns: [StripColumn],
        viewport: StripViewport
    ) -> Double {
        guard columnIndex >= 0 && columnIndex < columns.count else {
            return viewport.scrollOffset
        }

        if columns[columnIndex].isPinned {
            return 0.0
        }

        let availW = viewport.availableWidth
        let gap = viewport.gap
        let inset = viewport.inset

        let pinnedColIndex = columns.firstIndex(where: { $0.isPinned })
        let pinnedW =
            pinnedColIndex.map {
                max(120.0, round(columns[$0].widthFraction * (availW + gap) - gap))
            } ?? 0.0
        let scrollAvailW =
            (pinnedColIndex != nil)
            ? max(120.0, availW - pinnedW - gap)
            : availW

        var stripX = (pinnedColIndex != nil) ? 0.0 : inset
        for i in 0..<columnIndex {
            if !columns[i].isPinned {
                let w = max(120.0, round(columns[i].widthFraction * (scrollAvailW + gap) - gap))
                stripX += w + gap
            }
        }
        let targetW = max(
            120.0,
            round(columns[columnIndex].widthFraction * (scrollAvailW + gap) - gap)
        )

        let colMidX = stripX + targetW / 2.0
        let effectiveScreenWidth = (pinnedColIndex != nil) ? scrollAvailW : viewport.screenWidth
        let targetScroll = colMidX - effectiveScreenWidth / 2.0

        let layout = computeLayout(columns: columns, viewport: viewport)
        return max(0.0, min(targetScroll, layout.maxScrollOffset))
    }

    /// Cycles the width of a column through presets (25%, 33%, 50%, 66%, 75%, 100%).
    public static func cycleWidth(
        currentFraction: Double,
        presets: [Double] = defaultWidthPresets
    ) -> Double {
        guard !presets.isEmpty else { return 0.5 }
        for p in presets where p > currentFraction + 0.01 {
            return p
        }
        return presets[0]
    }

    /// Toggles between full width (1.0) and previous/default width.
    public static func toggleFullWidth(
        currentFraction: Double,
        savedFraction: Double?
    ) -> (newFraction: Double, saved: Double?) {
        if currentFraction >= 0.98 {
            return (savedFraction ?? 0.5, nil)
        } else {
            return (1.0, currentFraction)
        }
    }

    /// Finds the first column index that contains an agent requesting human approval.
    public static func findApprovalColumnIndex(columns: [StripColumn]) -> Int? {
        columns.firstIndex { col in
            col.windows.contains { $0.agentStatus == .needsApproval }
        }
    }

    /// Finds the first column index associated with an agent by name.
    public static func findAgentColumnIndex(
        agentName: String,
        columns: [StripColumn]
    ) -> Int? {
        let needle = agentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return columns.firstIndex { col in
            col.windows.contains {
                ($0.agentName ?? "").lowercased().contains(needle)
                    || $0.title.lowercased().contains(needle)
            }
        }
    }

    /// Finds a window by ID across every column and row.
    public static func findWindow(
        id: String,
        columns: [StripColumn]
    ) -> (column: Int, row: Int)? {
        for (columnIndex, column) in columns.enumerated() {
            if let row = column.windows.firstIndex(where: { $0.id == id }) {
                return (columnIndex, row)
            }
        }
        return nil
    }

    /// Next row in a column, wrapping at the end.
    public static func nextRow(current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (max(0, min(current, count - 1)) + 1) % count
    }

    /// Previous row in a column, wrapping at the start.
    public static func previousRow(current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (max(0, min(current, count - 1)) + count - 1) % count
    }

    /// Stacks a window from source column into target column.
    public static func stack(
        sourceColIndex: Int,
        targetColIndex: Int,
        columns: inout [StripColumn]
    ) -> Bool {
        guard sourceColIndex != targetColIndex,
            sourceColIndex >= 0, sourceColIndex < columns.count,
            targetColIndex >= 0, targetColIndex < columns.count
        else {
            return false
        }

        var source = columns[sourceColIndex]
        guard !source.windows.isEmpty else { return false }
        let winIdx = max(0, min(source.focusedRow, source.windows.count - 1))
        let movingWin = source.windows.remove(at: winIdx)

        columns[targetColIndex].windows.append(movingWin)
        columns[targetColIndex].focusedRow = columns[targetColIndex].windows.count - 1

        if source.windows.isEmpty {
            columns.remove(at: sourceColIndex)
        } else {
            source.focusedRow = max(0, min(source.focusedRow, source.windows.count - 1))
            columns[sourceColIndex] = source
        }
        return true
    }

    /// Pops out the focused window of a column into its own adjacent column.
    public static func unstack(
        columnIndex: Int,
        popToRight: Bool,
        columns: inout [StripColumn]
    ) -> Bool {
        guard columnIndex >= 0, columnIndex < columns.count else { return false }
        var col = columns[columnIndex]
        guard col.windows.count >= 2 else { return false }

        let winIdx = max(0, min(col.focusedRow, col.windows.count - 1))
        let movingWin = col.windows.remove(at: winIdx)
        col.focusedRow = max(0, min(col.focusedRow, col.windows.count - 1))
        columns[columnIndex] = col

        let insertIdx = columnIndex + (popToRight ? 1 : 0)
        let newCol = StripColumn(
            windows: [movingWin],
            widthFraction: col.widthFraction,
            isTabbed: false,
            focusedRow: 0
        )
        columns.insert(newCol, at: insertIdx)
        return true
    }

    /// Swaps or reorders column positions.
    public static func reorder(
        fromIndex: Int,
        toIndex: Int,
        columns: inout [StripColumn]
    ) -> Bool {
        guard fromIndex != toIndex,
            fromIndex >= 0, fromIndex < columns.count,
            toIndex >= 0, toIndex < columns.count
        else {
            return false
        }
        let moving = columns.remove(at: fromIndex)
        columns.insert(moving, at: toIndex)
        return true
    }

    /// Computes bird's-eye zoom overview layout: scales all columns to fit on a single screen without scrolling.
    public static func computeOverviewLayout(
        columns: [StripColumn],
        viewport: StripViewport
    ) -> StripLayoutResult {
        guard !columns.isEmpty else { return StripLayoutResult() }

        let availW = viewport.availableWidth
        let availH = viewport.availableHeight
        let gap = viewport.gap
        let inset = viewport.inset

        let unscaled = computeLayout(columns: columns, viewport: viewport)
        let totalUnscaledW = max(1.0, unscaled.totalStripWidth - (2.0 * inset))
        let targetW = availW - (Double(columns.count - 1) * gap)
        let scale = min(1.0, max(0.15, targetW / totalUnscaledW))

        var colFrames: [StripRect] = []
        var winFrames: [String: StripRect] = [:]
        var visibleIDs = Set<String>()

        var currentX = viewport.screenOriginX + inset
        let scaledH = availH * scale
        let offsetY = viewport.screenOriginY + inset + ((availH - scaledH) / 2.0)

        for col in columns {
            let colW = max(60.0, round(col.widthFraction * (availW + gap) - gap) * scale)
            let colFrame = StripRect(
                x: currentX,
                y: offsetY,
                width: colW,
                height: scaledH
            )
            colFrames.append(colFrame)

            for win in col.windows {
                winFrames[win.id] = colFrame
                visibleIDs.insert(win.id)
            }
            currentX += colW + gap
        }

        let totalWidth = currentX - gap + inset - (viewport.screenOriginX)
        return StripLayoutResult(
            columnFrames: colFrames,
            windowFrames: winFrames,
            totalStripWidth: totalWidth,
            maxScrollOffset: 0.0,
            visibleWindowIDs: visibleIDs,
            offscreenLeftIDs: [],
            offscreenRightIDs: []
        )
    }

    /// Role of a window in the automatic agent workflow.
    public enum StripChainRole: String, Equatable, Sendable, CaseIterable {
        case ide
        case browser
        case terminal
        case other
    }

    /// Classifies a window for auto-chaining. Bundle identifiers win over
    /// title heuristics so a browser tab titled after an editor is not
    /// mistaken for the editor itself.
    public static func chainRole(for window: StripWindowInfo) -> StripChainRole {
        let bundle = window.appBundleID.lowercased()
        let title = window.title.lowercased()
        let agent = (window.agentName ?? "").lowercased()

        if isIDEBundle(bundle) || isIDEAgent(agent) {
            return .ide
        }
        if isBrowserBundle(bundle) {
            return .browser
        }
        if isTerminalBundle(bundle) {
            return .terminal
        }
        if title.contains("localhost") || title.contains("127.0.0.1")
            || title.contains("http://") || title.contains("https://")
        {
            return .browser
        }
        if isIDETitle(title) {
            return .ide
        }
        return .other
    }

    /// True when a window belongs to the supplied project slug. The agent
    /// working directory is the strongest signal; titles cover editors and
    /// browser tabs that expose the project name.
    public static func windowMatchesProject(_ window: StripWindowInfo, slug: String) -> Bool {
        let needle = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        if let cwd = window.agentCwd?.lowercased(), cwd.contains(needle) {
            return true
        }
        return window.title.lowercased().contains(needle)
    }

    private static func isIDEBundle(_ bundle: String) -> Bool {
        let markers = [
            "cursor", "antigravity", "windsurf", "xcode", "vscode",
            "visual studio code", "zed", "sublime", "jetbrains",
            "intellij", "pycharm", "webstorm", "goland", "rubymine",
            "android studio", "neovide", "com.todesktop.",
        ]
        return markers.contains { bundle.contains($0) }
    }

    private static func isIDEAgent(_ agent: String) -> Bool {
        let markers = ["cursor", "antigravity", "windsurf"]
        return markers.contains { agent.contains($0) }
    }

    private static func isIDETitle(_ title: String) -> Bool {
        let markers = [
            "visual studio code", " - cursor", " - antigravity", " - windsurf",
            " - zed", " - sublime text", " - intellij", " - pycharm",
            " - webstorm", " - goland", " - xcode",
        ]
        return markers.contains { title.contains($0) }
    }

    private static func isBrowserBundle(_ bundle: String) -> Bool {
        let markers = [
            "com.apple.safari", "safari", "chrome", "chromium", "edgemac",
            "microsoft.edge", "brave", "firefox", "opera", "vivaldi",
            "company.thebrowser.browser", "company.thebrowser.dia",
            "duckduckgo", "sidekick", "zen-browser", "zen_browser",
        ]
        return markers.contains { bundle.contains($0) }
    }

    private static func isTerminalBundle(_ bundle: String) -> Bool {
        let markers = [
            "com.apple.terminal", "iterm", "ghostty", "alacritty", "kitty",
            "wezterm", "warp", "hyper", "tabby", "termius",
        ]
        return markers.contains { bundle.contains($0) }
    }

    /// Automatically chains windows into an agent triage workflow:
    /// IDE (50%) -> Browser (30%) -> Terminal (20%) when all three stages are
    /// present.
    ///
    /// Widths are normalized across the stages that are present, so the
    /// resulting columns always sum to 1.0 and fit the viewport. A supplied
    /// project slug makes each stage prefer matching windows. A stage with no
    /// match keeps its windows, so a browser tab that omits the project name
    /// does not remove the browser stage. Windows outside the workflow are
    /// kept in a trailing Other column instead of being mislabeled as tests.
    public static func autoChainWorkflow(
        windows: [StripWindowInfo],
        projectSlug: String? = nil
    ) -> [StripColumn] {
        guard !windows.isEmpty else { return [] }

        var grouped: [StripChainRole: [StripWindowInfo]] = [:]
        for window in windows {
            grouped[chainRole(for: window), default: []].append(window)
        }

        let order: [StripChainRole] = [.ide, .browser, .terminal, .other]
        let weights: [StripChainRole: Double] = [
            .ide: 5.0,
            .browser: 3.0,
            .terminal: 2.0,
            .other: 1.0,
        ]
        let present = order.filter { !(grouped[$0] ?? []).isEmpty }
        let totalWeight = present.reduce(0.0) { $0 + (weights[$1] ?? 0.0) }
        guard totalWeight > 0 else { return [] }

        let slug = projectSlug?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var chained: [StripColumn] = []

        for role in present {
            let candidates = grouped[role] ?? []
            let selected: [StripWindowInfo]
            if slug.isEmpty {
                selected = candidates
            } else {
                let matches = candidates.filter { windowMatchesProject($0, slug: slug) }
                selected = matches.isEmpty ? candidates : matches
            }
            chained.append(
                StripColumn(
                    windows: selected,
                    widthFraction: (weights[role] ?? 0.0) / totalWeight,
                    isTabbed: selected.count > 1
                )
            )
        }

        return chained
    }
}
