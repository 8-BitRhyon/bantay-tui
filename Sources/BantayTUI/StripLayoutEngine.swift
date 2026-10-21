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

    public init(
        id: String,
        pid: Int32 = 0,
        appBundleID: String = "",
        title: String = "",
        agentName: String? = nil,
        agentCwd: String? = nil,
        agentStatus: StripAgentStatus = .idle
    ) {
        self.id = id
        self.pid = pid
        self.appBundleID = appBundleID
        self.title = title
        self.agentName = agentName
        self.agentCwd = agentCwd
        self.agentStatus = agentStatus
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
        viewport: StripViewport
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

        var stripX = inset

        for col in columns {
            let colW = max(120.0, round(col.widthFraction * (availW + gap) - gap))
            let colScreenX = viewport.screenOriginX + stripX - viewport.scrollOffset
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
                winFrames[win.id] = colFrame
                classifyVisibility(
                    frame: colFrame,
                    id: win.id,
                    viewport: viewport,
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
                                viewport: viewport,
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
                            viewport: viewport,
                            visibleIDs: &visibleIDs,
                            leftIDs: &leftIDs,
                            rightIDs: &rightIDs
                        )
                    }
                }
            }

            stripX += colW + gap
        }

        let totalStripWidth = stripX - gap + inset
        let maxScroll = max(0.0, totalStripWidth - viewport.screenWidth)

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

        let availW = viewport.availableWidth
        let gap = viewport.gap
        let inset = viewport.inset

        var stripX = inset
        for i in 0..<columnIndex {
            let w = max(120.0, round(columns[i].widthFraction * (availW + gap) - gap))
            stripX += w + gap
        }
        let targetW = max(
            120.0,
            round(columns[columnIndex].widthFraction * (availW + gap) - gap)
        )

        let colStripLeft = stripX
        let colStripRight = stripX + targetW

        let layout = computeLayout(columns: columns, viewport: viewport)
        let maxScroll = layout.maxScrollOffset

        var currentScroll = viewport.scrollOffset
        let leftBound = colStripLeft - gap
        let rightBound = colStripRight + gap

        if leftBound < currentScroll {
            currentScroll = leftBound
        } else if rightBound > currentScroll + viewport.screenWidth {
            currentScroll = rightBound - viewport.screenWidth
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

        let availW = viewport.availableWidth
        let gap = viewport.gap
        let inset = viewport.inset

        var stripX = inset
        for i in 0..<columnIndex {
            let w = max(120.0, round(columns[i].widthFraction * (availW + gap) - gap))
            stripX += w + gap
        }
        let targetW = max(
            120.0,
            round(columns[columnIndex].widthFraction * (availW + gap) - gap)
        )

        let colMidX = stripX + targetW / 2.0
        let targetScroll = colMidX - viewport.screenWidth / 2.0

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
}
