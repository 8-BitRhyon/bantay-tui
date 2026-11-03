#if canImport(Testing)
    import Foundation
    import Testing

    @testable import BantayTUI

    @MainActor
    @Suite("Task store deduplication and resurrection guards", .serialized)
    struct TaskDedupeTests {
        private func isolatedStore() -> TaskStore {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-task-dedupe-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("tasks.json")
            try? Data().write(to: file, options: [.atomic])
            return TaskStore(fileURL: file)
        }

        @Test("adding the same title twice keeps one task")
        func addTaskDedupesIdenticalTitle() {
            let manager = isolatedStore()
            let first = manager.addTask("Buy milk", syncReminders: false)
            let second = manager.addTask("buy MILK", syncReminders: false)
            #expect(manager.tasks.count == 1)
            #expect(first.id == second.id)
        }

        @Test("same title with different tags stays separate")
        func tagsDistinguishReminders() {
            let manager = isolatedStore()
            _ = manager.batchIngestExternalReminders([
                (rawTitle: "Buy milk @work", dueDate: nil, externalID: "r1"),
                (rawTitle: "Buy milk @home", dueDate: nil, externalID: "r2"),
            ])
            #expect(manager.tasks.count == 2)
        }

        @Test("identical ingest twice keeps one task")
        func ingestIsIdempotent() {
            let manager = isolatedStore()
            let batch = [(rawTitle: "Plan trip", dueDate: nil as Date?, externalID: "rx")]
            _ = manager.batchIngestExternalReminders(batch)
            _ = manager.batchIngestExternalReminders(batch)
            #expect(manager.tasks.count == 1)
        }

        @Test("deleted tasks stay deleted after relaunch")
        func tombstonesSurviveRelaunch() async {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-task-tomb-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("tasks.json")
            try? Data().write(to: file, options: [.atomic])
            let first = TaskStore(fileURL: file)
            _ = first.batchIngestExternalReminders([
                (rawTitle: "Water plants", dueDate: nil, externalID: "ext-1")
            ])
            #expect(first.tasks.count == 1)
            first.removeTask(first.tasks[0].id)
            await first.waitForPendingWrites()

            let second = TaskStore(fileURL: file)
            _ = second.batchIngestExternalReminders([
                (rawTitle: "Water plants", dueDate: nil, externalID: "ext-1")
            ])
            #expect(second.tasks.isEmpty)
        }

        @Test("externalID match wins over same-title rows")
        func indexPrefersExternalID() {
            let manager = isolatedStore()
            // Tagless same-title reminders merge rather than duplicate:
            // with no distinguishing signal, one task is the honest answer.
            _ = manager.batchIngestExternalReminders([
                (rawTitle: "Report", dueDate: nil, externalID: "r-a"),
                (rawTitle: "Report", dueDate: nil, externalID: nil),
            ])
            #expect(manager.tasks.count == 1)
            // The linked reminder resolves to the linked task even when
            // the title does not match.
            let idx = manager.indexOfTask(matchingExternalID: "R-A", title: "Nope")
            #expect(idx != nil)
            #expect(manager.tasks[idx!].externalID == "r-a")
            // A title match never steals a task that carries a different
            // externalID: that lookup must miss instead of misfiring.
            let steal = manager.indexOfTask(matchingExternalID: "zzz", title: "Report")
            #expect(steal == nil)
        }

        @Test("restoreTask brings back the exact task")
        func restoreReinsertsTask() {
            let manager = isolatedStore()
            let created = manager.addTask("Temporary", syncReminders: false)
            manager.removeTask(created.id)
            #expect(manager.tasks.isEmpty)
            manager.restoreTask(created)
            #expect(manager.tasks.count == 1)
            #expect(manager.tasks.first?.id == created.id)
            // And it does not resurrect anything else on re-ingest.
            _ = manager.batchIngestExternalReminders([
                (rawTitle: "Temporary", dueDate: nil, externalID: nil)
            ])
            #expect(manager.tasks.count == 1)
        }
    }
#endif
