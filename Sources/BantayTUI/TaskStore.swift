import Foundation

/// Main store for human and agent tasks in Bantay-TUI.
/// Manages JSON persistence and natural language quick-add parsing.
@MainActor
public final class TaskStore: ObservableObject {
    public static let shared = TaskStore()

    /// Maximum task capacity to prevent unbounded file growth and UI hangs.
    public static let maxCapacity = 200

    @Published public private(set) var tasks: [BantayTask] = []

    private let fileURL: URL
    private let writer = TaskDiskWriter()
    private var writeGeneration: UInt64 = 0
    private var tombstones: Set<String> = []

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

    /// Load tasks from JSON storage with automatic capacity clamping.
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
            saveSync()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded = try decoder.decode([BantayTask].self, from: data)
            if loaded.count > Self.maxCapacity {
                loaded = Array(loaded.prefix(Self.maxCapacity))
            }
            self.tasks = loaded
        } catch {
            self.tasks = []
        }
    }

    /// Asynchronously saves tasks to JSON storage off the main actor with monotonic generation ordering.
    public func save() {
        enforceCapacityLimit()
        writeGeneration += 1
        let gen = writeGeneration
        let snapshot = self.tasks
        let targetURL = self.fileURL
        Task.detached(priority: .utility) { [writer] in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            await writer.write(data: data, to: targetURL, generation: gen)
        }
    }

    /// Synchronously writes tasks to disk (used for tests and deterministic exits).
    public func saveSync() {
        enforceCapacityLimit()
        writeGeneration += 1
        let gen = writeGeneration
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(tasks)
            try data.write(to: fileURL, options: .atomic)
            Task { [writer] in
                await writer.recordExternalWrite(generation: gen)
            }
        } catch {
            // Silently swallow write errors
        }
    }

    private func enforceCapacityLimit() {
        guard tasks.count > Self.maxCapacity else { return }
        let incomplete = tasks.filter { !$0.isCompleted }
        let completed = tasks.filter { $0.isCompleted }
        let allowedCompleted = max(0, Self.maxCapacity - incomplete.count)
        let keptCompleted = Array(completed.prefix(allowedCompleted))
        tasks = Array((incomplete + keptCompleted).prefix(Self.maxCapacity))
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
        let clean = parsed.cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !clean.isEmpty {
            tombstones.remove(clean)
        }
        let raw = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !raw.isEmpty {
            tombstones.remove(raw)
        }

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

    /// Ingests a task discovered externally (e.g. from Apple Reminders via iCloud).
    /// Uses tombstones and externalID to avoid duplicate or resurrected tasks.
    @discardableResult
    public func ingestExternalReminder(
        rawTitle: String,
        dueDate: Date? = nil,
        externalID: String? = nil
    ) -> BantayTask? {
        let batch = batchIngestExternalReminders([
            (rawTitle: rawTitle, dueDate: dueDate, externalID: externalID)
        ])
        return batch.first
    }

    /// Ingests a batch of external reminders, deduplicating and saving only once at the end.
    @discardableResult
    public func batchIngestExternalReminders(
        _ items: [(rawTitle: String, dueDate: Date?, externalID: String?)]
    ) -> [BantayTask] {
        var ingested: [BantayTask] = []

        for item in items {
            let parsed = TaskStore.parseNaturalLanguage(item.rawTitle)
            let trimmedTitle = parsed.cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { continue }

            // Check tombstones to prevent resurrecting deleted items
            let lowerTitle = trimmedTitle.lowercased()
            let lowerExt = item.externalID?.lowercased()
            if tombstones.contains(lowerTitle) { continue }
            if let lowerExt, tombstones.contains(lowerExt) { continue }

            // Deduplication: externalID match first, then clean/raw title comparison
            let rawTrimmed = item.rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existingIndex = tasks.firstIndex(where: { task in
                if let ext = item.externalID, let taskExt = task.externalID, !ext.isEmpty,
                    !taskExt.isEmpty
                {
                    if ext.caseInsensitiveCompare(taskExt) == .orderedSame { return true }
                }
                return task.title.caseInsensitiveCompare(trimmedTitle) == .orderedSame
                    || task.title.caseInsensitiveCompare(rawTrimmed) == .orderedSame
            }) {
                // Backfill externalID if missing so future status syncs link properly
                if tasks[existingIndex].externalID == nil, let ext = item.externalID {
                    tasks[existingIndex].externalID = ext
                }
                continue
            }

            let finalDueDate = item.dueDate ?? parsed.dueDate
            let task = BantayTask(
                title: trimmedTitle,
                dueDate: finalDueDate,
                priority: parsed.priority,
                tags: parsed.tags,
                assignedAgent: parsed.assignedAgent,
                externalID: item.externalID
            )
            tasks.insert(task, at: 0)
            ingested.append(task)
        }

        if !ingested.isEmpty {
            save()
            if NotchHUDConfig.shared.autoDispatchTasks {
                for task in ingested where task.assignedAgent != nil {
                    dispatchTask(task.id)
                }
            }
        }

        return ingested
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

            let newState: TaskExecutionState
            switch kind {
            case .completed:
                newState = .completed
            case .failed, .cancelled:
                newState = .failed
            case .accessRequest, .waiting:
                newState = .blocked
            case .progress, .started:
                newState = .working
            default:
                newState = task.executionState
            }

            guard newState != task.executionState else { continue }

            task.executionState = newState
            if newState == .completed {
                task.isCompleted = true
                task.completedAt = Date()
                NotchHUDConfig.shared.addMascotXP(25)
            }
            tasks[index] = task
            changed = true
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
            let extID = task.externalID
            let isDone = task.isCompleted
            Task {
                let matching = RemindersProvider.shared.reminders.first(where: {
                    if let extID, $0.calendarItemIdentifier == extID { return true }
                    return $0.title == targetTitle
                })
                if let matching, isDone {
                    await RemindersProvider.shared.complete(matching)
                }
            }
        }
    }

    /// Removes a task, adding its identifier to the tombstone list to prevent sync resurrection.
    public func removeTask(_ taskID: UUID) {
        if let target = tasks.first(where: { $0.id == taskID }) {
            tombstones.insert(target.id.uuidString.lowercased())
            if let ext = target.externalID, !ext.isEmpty {
                tombstones.insert(ext.lowercased())
            }
            let clean = target.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !clean.isEmpty {
                tombstones.insert(clean)
            }

            let targetTitle = target.title
            let extID = target.externalID
            if NotchHUDConfig.shared.syncAppleReminders && RemindersProvider.shared.isAuthorized {
                Task {
                    let matching = RemindersProvider.shared.reminders.first(where: {
                        if let extID, $0.calendarItemIdentifier == extID { return true }
                        return $0.title == targetTitle
                    })
                    if let matching {
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

    /// Single-pass categorized tasks struct for high-performance rendering.
    public struct CategorizedTasks: Equatable, Sendable {
        public let overdue: [BantayTask]
        public let today: [BantayTask]
        public let later: [BantayTask]
        public let completed: [BantayTask]
        public let doneTodayCount: Int

        public var isEmpty: Bool {
            overdue.isEmpty && today.isEmpty && later.isEmpty && completed.isEmpty
        }
    }

    /// Categorizes tasks in a single O(N) pass, avoiding redundant iterations and calendar calls.
    public func categorizedTasks(
        searchQuery: String = "", relativeTo now: Date = Date()
    ) -> CategorizedTasks {
        var overdue: [BantayTask] = []
        var today: [BantayTask] = []
        var later: [BantayTask] = []
        var completed: [BantayTask] = []
        var doneToday = 0

        let calendar = Calendar.current
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuery = !trimmedQuery.isEmpty

        for task in tasks {
            if task.isCompleted, let completedAt = task.completedAt,
                calendar.isDate(completedAt, inSameDayAs: now)
            {
                doneToday += 1
            }

            if hasQuery {
                let matches =
                    task.title.localizedCaseInsensitiveContains(trimmedQuery)
                    || task.tags.contains(where: {
                        $0.localizedCaseInsensitiveContains(trimmedQuery)
                    })
                    || (task.assignedAgent?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                guard matches else { continue }
            }

            switch task.category(relativeTo: now) {
            case .overdue: overdue.append(task)
            case .today: today.append(task)
            case .later: later.append(task)
            case .completed: completed.append(task)
            }
        }

        let sortBlock = { (t1: BantayTask, t2: BantayTask) -> Bool in
            if t1.priority != t2.priority { return t1.priority < t2.priority }
            return (t1.dueDate ?? t1.createdAt) < (t2.dueDate ?? t2.createdAt)
        }

        return CategorizedTasks(
            overdue: overdue.sorted(by: sortBlock),
            today: today.sorted(by: sortBlock),
            later: later.sorted(by: sortBlock),
            completed: completed.sorted(by: sortBlock),
            doneTodayCount: doneToday
        )
    }

    /// Returns tasks matching a category and optional search filter.
    public func tasks(
        in category: TaskCategory, searchQuery: String = "", relativeTo now: Date = Date()
    ) -> [BantayTask] {
        let cat = categorizedTasks(searchQuery: searchQuery, relativeTo: now)
        switch category {
        case .overdue: return cat.overdue
        case .today: return cat.today
        case .later: return cat.later
        case .completed: return cat.completed
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

/// Serial actor handling file writes off the main actor in strict chronological order.
private actor TaskDiskWriter {
    private var lastWrittenGeneration: UInt64 = 0

    func write(data: Data, to url: URL, generation: UInt64) {
        guard generation > lastWrittenGeneration else { return }
        do {
            try data.write(to: url, options: .atomic)
            lastWrittenGeneration = generation
        } catch {}
    }

    func recordExternalWrite(generation: UInt64) {
        if generation > lastWrittenGeneration {
            lastWrittenGeneration = generation
        }
    }
}
