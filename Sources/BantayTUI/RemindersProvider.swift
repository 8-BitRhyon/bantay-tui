import AppKit
@preconcurrency import EventKit
import Foundation

/// Live bridge to Apple Reminders via EventKit.
@MainActor
public final class RemindersProvider: ObservableObject {
    public static let shared = RemindersProvider()

    @Published public private(set) var authorized = false
    @Published public private(set) var reminders: [EKReminder] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var defaultList: EKCalendar?

    private var _store: EKEventStore?
    private var store: EKEventStore? {
        guard ApprovalNotificationController.hasBundleProxy else { return nil }
        if _store == nil {
            _store = EKEventStore()
        }
        return _store
    }

    private var eventStoreObserver: NSObjectProtocol?
    private var debounceSyncTask: Task<Void, Never>?

    /// Timestamp of our most recent EventKit write. Change notifications
    /// arriving inside the suppression window are our own echo, not external
    /// edits — syncing them back is churn that masks real failures.
    private var lastOwnWriteAt: Date?
    static let echoSuppressionSeconds: TimeInterval = 3

    /// Pure echo gate: suppress inbound sync this soon after an own write.
    static func shouldSuppressInboundSync(
        lastOwnWrite: Date?, now: Date = Date()
    ) -> Bool {
        guard let lastOwnWrite else { return false }
        return now.timeIntervalSince(lastOwnWrite) < echoSuppressionSeconds
    }

    private init() {
        checkAuthorizationStatus()
    }

    /// Check system authorization status and cache default calendar list.
    public func checkAuthorizationStatus() {
        let auth = isAuthorized
        authorized = auth
        if auth {
            startStoreObserver()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.defaultList = self.store?.defaultCalendarForNewReminders()
            }
        }
    }

    /// Listens for iCloud / background updates to the EventStore.
    public func startStoreObserver() {
        guard ApprovalNotificationController.hasBundleProxy else { return }
        guard eventStoreObserver == nil else { return }
        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.debounceInboundSync()
            }
        }
    }

    private func debounceInboundSync() {
        debounceSyncTask?.cancel()
        debounceSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard !Self.shouldSuppressInboundSync(lastOwnWrite: lastOwnWriteAt) else {
                return
            }
            await self.syncInboundReminders()
        }
    }

    /// True when Reminders access was denied or restricted. Re-prompting in
    /// this state is a no-op — the UI must deep-link to System Settings.
    public var permissionDenied: Bool {
        guard ApprovalNotificationController.hasBundleProxy else { return false }
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .denied, .restricted:
            return true
        default:
            return false
        }
    }

    /// Opens Privacy settings at Reminders when the grant was denied.
    public func openPrivacySettings() {
        let modern =
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Reminders"
        let legacy =
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        if let url = URL(string: modern), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: legacy) { NSWorkspace.shared.open(url) }
    }

    /// Background inbound sync from Apple Reminders into Bantay TaskStore using
    /// the default shared store.
    public func syncInboundReminders() async {
        await syncInboundReminders(into: .shared)
    }

    /// Background inbound sync from Apple Reminders into an explicit TaskStore.
    public func syncInboundReminders(into taskStore: TaskStore) async {
        guard NotchHUDConfig.shared.syncAppleReminders, isAuthorized else { return }
        await refresh()
        let batch: [(rawTitle: String, dueDate: Date?, externalID: String?)] = reminders.compactMap
        { item in
            guard let title = item.title, !title.isEmpty else { return nil }
            return (
                rawTitle: title, dueDate: item.dueDateComponents?.date,
                externalID: item.calendarItemIdentifier
            )
        }
        taskStore.batchIngestExternalReminders(batch)
    }

    /// Whether Reminders access is already granted (macOS 13-safe; the 14+
    /// `.fullAccess` enum case is mapped to authorized here).
    public var isAuthorized: Bool {
        guard ApprovalNotificationController.hasBundleProxy else { return false }
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .authorized, .fullAccess:
            return true
        default:
            return false
        }
    }

    /// Request Reminders permission (prompts once).
    public func requestAccess() async -> Bool {
        guard ApprovalNotificationController.hasBundleProxy else { return false }
        do {
            let granted = try await Self.performAccessRequest()
            authorized = granted
            if granted { defaultList = store?.defaultCalendarForNewReminders() }
            return granted
        } catch {
            authorized = false
            return false
        }
    }

    nonisolated private static func performAccessRequest() async throws -> Bool {
        let localStore = EKEventStore()
        if #available(macOS 14.0, *) {
            return try await localStore.requestFullAccessToReminders()
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                localStore.requestAccess(to: .reminder) { ok, err in
                    if let err {
                        continuation.resume(throwing: err)
                    } else {
                        continuation.resume(returning: ok)
                    }
                }
            }
        }
    }

    /// Ensure we have access, requesting if needed.
    public func ensureAccess() async -> Bool {
        if isAuthorized {
            authorized = true
            if defaultList == nil {
                defaultList = store?.defaultCalendarForNewReminders()
            }
            return true
        }
        return await requestAccess()
    }

    /// Refresh reminders from the default list, newest-sorted by due date.
    public func refresh() async {
        guard isAuthorized else {
            authorized = false
            reminders = []
            return
        }
        authorized = true
        if defaultList == nil {
            defaultList = store?.defaultCalendarForNewReminders()
        }
        isLoading = true
        defer { isLoading = false }
        guard let store else { return }
        let calendar = defaultList ?? store.defaultCalendarForNewReminders()
        guard let calendar else { return }
        let predicate = store.predicateForReminders(in: [calendar])
        // Coordinate EventKit fetch and timeout safely.
        let gate = AtomicRemindersGate()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.fetchReminders(matching: predicate) { items in
                gate.resume(with: items ?? [], continuation: cont)
            }
            // Timeout fallback after 2.0s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                gate.resume(with: [], continuation: cont)
            }
        }
        reminders = gate.items
            .filter { !$0.isCompleted }
            .sorted {
                ($0.dueDateComponents?.date ?? .distantFuture)
                    < ($1.dueDateComponents?.date ?? .distantFuture)
            }
    }

    /// Add a reminder to the default list.
    @discardableResult
    public func add(title: String, due: Date? = nil) async -> Bool {
        guard await ensureAccess() else { return false }
        guard let store else { return false }
        let list = defaultList ?? store.defaultCalendarForNewReminders()
        guard let list else { return false }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        do {
            try store.save(reminder, commit: true)
            lastOwnWriteAt = Date()
            await refresh()
            return true
        } catch {
            return false
        }
    }

    /// Mark a reminder complete.
    public func complete(_ reminder: EKReminder) async {
        guard let store else { return }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
            lastOwnWriteAt = Date()
            await refresh()
        } catch {
            reminder.isCompleted = false
        }
    }

    /// Reopen a reminder that a task un-completion should restore. Needs a
    /// fetch that INCLUDES completed items, since `refresh()` deliberately
    /// filters them out.
    public func reopen(matchingTitle title: String, externalID: String?) async {
        guard await ensureAccess(), let store else { return }
        let calendar = defaultList ?? store.defaultCalendarForNewReminders()
        guard let calendar else { return }
        let predicate = store.predicateForReminders(in: [calendar])
        let gate = AtomicRemindersGate()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.fetchReminders(matching: predicate) { items in
                gate.resume(with: items ?? [], continuation: cont)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                gate.resume(with: [], continuation: cont)
            }
        }
        let match = gate.items.first { item in
            if let externalID, item.calendarItemIdentifier == externalID { return true }
            return item.title == title
        }
        guard let match, match.isCompleted else { return }
        match.isCompleted = false
        do {
            try store.save(match, commit: true)
            lastOwnWriteAt = Date()
            await refresh()
        } catch {
            match.isCompleted = true
        }
    }

    /// Remove a reminder.
    public func remove(_ reminder: EKReminder) async {
        guard let store else { return }
        do {
            try store.remove(reminder, commit: true)
            lastOwnWriteAt = Date()
            await refresh()
        } catch {}
    }
}

/// Thread-safe single-resume gate coordinating EKReminder results.
public final class AtomicRemindersGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    public var items: [EKReminder] = []

    public init() {}

    @discardableResult
    public func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }

    public func resume(with items: [EKReminder], continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        self.items = items
        continuation.resume()
    }
}
