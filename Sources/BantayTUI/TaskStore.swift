import Foundation

/// Main store for human and agent tasks in Bantay-TUI.
/// Manages JSON persistence and natural language quick-add parsing.
@MainActor
public final class TaskStore: ObservableObject {
    public static let shared = TaskStore()

    @Published public private(set) var tasks: [BantayTask] = []

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.appendingPathComponent("Bantay-TUI", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: appSupport, withIntermediateDirectories: true)
            self.fileURL = appSupport.appendingPathComponent("tasks.json")
        }
        load()
    }

    /// Load tasks from JSON storage.
    public func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Provide default welcoming task items on first launch
            self.tasks = [
                BantayTask(
                    title: "Welcome to Bantay Task Manager! Try adding a task below.",
                    priority: .high,
                    tags: ["welcome"]
                ),
                BantayTask(
                    title: "Assign a prompt task to your AI agent @claude",
                    priority: .medium,
                    tags: ["agent"],
                    assignedAgent: "claude"
                ),
            ]
            save()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.tasks = try decoder.decode([BantayTask].self, from: data)
        } catch {
            self.tasks = []
        }
    }

    /// Save tasks to JSON storage.
    public func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(tasks)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Silently swallow write errors
        }
    }

    /// Dopamine counter: number of tasks marked completed today.
    public var doneTodayCount: Int {
        let calendar = Calendar.current
        return tasks.filter { task in
            guard task.isCompleted, let completedAt = task.completedAt else { return false }
            return calendar.isDateInToday(completedAt)
        }.count
    }

    /// Adds a new task, using natural language tag/agent/priority parsing if needed.
    @discardableResult
    public func addTask(_ rawTitle: String, dueDate: Date? = nil, syncReminders: Bool = true)
        -> BantayTask
    {
        let parsed = TaskStore.parseNaturalLanguage(rawTitle)
        let finalDueDate = dueDate ?? parsed.dueDate
        let task = BantayTask(
            title: parsed.cleanTitle,
            dueDate: finalDueDate,
            priority: parsed.priority,
            tags: parsed.tags,
            assignedAgent: parsed.assignedAgent
        )
        tasks.insert(task, at: 0)
        save()

        if task.assignedAgent != nil && NotchHUDConfig.shared.autoDispatchTasks {
            dispatchTask(task.id)
        }

        if syncReminders && NotchHUDConfig.shared.syncAppleReminders
            && RemindersProvider.shared.isAuthorized
        {
            let taskTitle = task.title
            let taskDue = task.dueDate
            Task {
                await RemindersProvider.shared.add(title: taskTitle, due: taskDue)
            }
        }
        return task
    }

    /// Dispatches an agent task to its target process or multiplexer pane.
    public func dispatchTask(_ taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        var task = tasks[index]
        guard !task.isCompleted else { return }

        let isAllowed = TaskDispatcher.isDispatchAllowed(
            cost: AgentEventManager.shared.usage.costUSD,
            budget: NotchHUDConfig.shared.dailyBudgetUSD,
            enforceLimit: NotchHUDConfig.shared.enforceBudgetLimit
        )
        guard isAllowed else {
            task.executionState = .blocked
            tasks[index] = task
            save()
            return
        }

        let linkedPane = TaskDispatcher.shared.dispatch(task: task)
        task.executionState = .dispatched
        task.linkedPaneID = linkedPane
        task.dispatchedAt = Date()
        tasks[index] = task
        save()
    }

    /// Updates task states matching an incoming agent event.
    func updateTaskState(paneId: String?, source: String, kind: AgentEventKind) {
        var changed = false
        for index in 0..<tasks.count {
            var task = tasks[index]
            guard !task.isCompleted else { continue }
            let matchesPane = paneId != nil && task.linkedPaneID == paneId
            let matchesSource = task.assignedAgent?.lowercased() == source.lowercased()
            guard matchesPane || matchesSource else { continue }

            switch kind {
            case .completed:
                task.executionState = .completed
                task.isCompleted = true
                task.completedAt = Date()
                NotchHUDConfig.shared.addMascotXP(25)
                changed = true
            case .failed, .cancelled:
                task.executionState = .failed
                changed = true
            case .accessRequest, .waiting:
                task.executionState = .blocked
                changed = true
            case .progress, .started:
                task.executionState = .working
                changed = true
            default:
                break
            }
            tasks[index] = task
        }
        if changed { save() }
    }

    /// Toggles completion state of a task.
    public func toggleCompleted(_ taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        var task = tasks[index]
        task.isCompleted.toggle()
        task.completedAt = task.isCompleted ? Date() : nil
        tasks[index] = task
        save()

        if NotchHUDConfig.shared.syncAppleReminders && RemindersProvider.shared.isAuthorized {
            let targetTitle = task.title
            let isDone = task.isCompleted
            Task {
                if let matching = RemindersProvider.shared.reminders.first(where: {
                    $0.title == targetTitle
                }) {
                    if isDone {
                        await RemindersProvider.shared.complete(matching)
                    }
                }
            }
        }
    }

    /// Removes a task.
    public func removeTask(_ taskID: UUID) {
        if let target = tasks.first(where: { $0.id == taskID }) {
            let targetTitle = target.title
            if NotchHUDConfig.shared.syncAppleReminders && RemindersProvider.shared.isAuthorized {
                Task {
                    if let matching = RemindersProvider.shared.reminders.first(where: {
                        $0.title == targetTitle
                    }) {
                        await RemindersProvider.shared.remove(matching)
                    }
                }
            }
        }
        tasks.removeAll(where: { $0.id == taskID })
        save()
    }

    /// Assigns an agent source name to a task.
    public func assignAgent(_ taskID: UUID, agent: String?) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].assignedAgent = agent
        save()
    }

    /// Returns tasks matching a category and optional search filter.
    public func tasks(
        in category: TaskCategory, searchQuery: String = "", relativeTo now: Date = Date()
    ) -> [BantayTask] {
        tasks.filter { task in
            guard task.category(relativeTo: now) == category else { return false }
            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            return task.title.localizedCaseInsensitiveContains(searchQuery)
                || task.tags.contains(where: { $0.localizedCaseInsensitiveContains(searchQuery) })
                || (task.assignedAgent?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        }
        .sorted { (t1, t2) -> Bool in
            if t1.priority != t2.priority { return t1.priority < t2.priority }
            return (t1.dueDate ?? t1.createdAt) < (t2.dueDate ?? t2.createdAt)
        }
    }

    /// Natural language title parser for tags (`@work`), priorities (`!!`), and agents (`@claude`, `@herdr`).
    public struct ParsedTask: Equatable, Sendable {
        public var cleanTitle: String
        public var tags: [String]
        public var priority: TaskPriority
        public var assignedAgent: String?
        public var dueDate: Date?

        public init(
            cleanTitle: String, tags: [String] = [], priority: TaskPriority = .medium,
            assignedAgent: String? = nil, dueDate: Date? = nil
        ) {
            self.cleanTitle = cleanTitle
            self.tags = tags
            self.priority = priority
            self.assignedAgent = assignedAgent
            self.dueDate = dueDate
        }

        init(from parsed: NaturalLanguageParser.Parsed) {
            self.cleanTitle = parsed.cleanTitle
            self.tags = parsed.tags
            self.priority = parsed.priority
            self.assignedAgent = parsed.assignedAgent
            self.dueDate = parsed.dueDate
        }
    }

    public static func parseNaturalLanguage(_ input: String, now: Date = Date()) -> ParsedTask {
        ParsedTask(from: NaturalLanguageParser.parse(input, now: now))
    }
}
