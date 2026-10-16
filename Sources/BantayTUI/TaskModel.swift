import Foundation
import SwiftUI

/// Priority level for a task item.
public enum TaskPriority: String, Codable, CaseIterable, Comparable, Sendable {
    case low = "low"
    case medium = "medium"
    case high = "high"

    public var sortOrder: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    public var badgeSymbol: String {
        switch self {
        case .high: return "!!"
        case .medium: return "!"
        case .low: return ""
        }
    }

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// Categorized section grouping.
public enum TaskCategory: String, Codable, CaseIterable, Sendable {
    case overdue = "OVERDUE"
    case today = "TODAY"
    case later = "LATER"
    case completed = "COMPLETED"

    public var colorHex: String {
        switch self {
        case .overdue: return "FF453A"  // Red
        case .today: return "FF9F0A"  // Amber/Orange
        case .later: return "64D2FF"  // Cyan/Blue
        case .completed: return "30D158"  // Green
        }
    }
}

/// Execution lifecycle state for agent-dispatched tasks.
public enum TaskExecutionState: String, Codable, CaseIterable, Sendable {
    case pending = "pending"
    case dispatched = "dispatched"
    case working = "working"
    case blocked = "blocked"
    case completed = "completed"
    case failed = "failed"
}

/// A human or agent task item managed by Bantay-TUI.
public struct BantayTask: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var dueDate: Date?
    public var priority: TaskPriority
    public var tags: [String]
    public var assignedAgent: String?
    public var executionState: TaskExecutionState
    public var linkedPaneID: String?
    public var dispatchedAt: Date?
    public var isCompleted: Bool
    public var createdAt: Date
    public var completedAt: Date?
    public var externalID: String?

    public init(
        id: UUID = UUID(),
        title: String,
        dueDate: Date? = nil,
        priority: TaskPriority = .medium,
        tags: [String] = [],
        assignedAgent: String? = nil,
        executionState: TaskExecutionState = .pending,
        linkedPaneID: String? = nil,
        dispatchedAt: Date? = nil,
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        externalID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.priority = priority
        self.tags = tags
        self.assignedAgent = assignedAgent
        self.executionState = isCompleted ? .completed : executionState
        self.linkedPaneID = linkedPaneID
        self.dispatchedAt = dispatchedAt
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.externalID = externalID
    }

    /// Computes category dynamically based on completion and dueDate relative to today.
    public func category(relativeTo now: Date = Date()) -> TaskCategory {
        if isCompleted { return .completed }
        guard let dueDate else { return .today }

        let calendar = Calendar.current
        if calendar.isDate(dueDate, inSameDayAs: now) {
            return .today
        } else if dueDate < calendar.startOfDay(for: now) {
            return .overdue
        } else {
            return .later
        }
    }
}

extension Color {
    public init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
