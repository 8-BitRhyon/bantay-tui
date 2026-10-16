import Combine
import Foundation

@MainActor
public final class NotesStore: ObservableObject {
    public static let shared = NotesStore()

    @Published public var noteText: String = "" {
        didSet {
            scheduleSave()
        }
    }

    private var saveTask: Task<Void, Never>?
    private let fileURL: URL
    private var isInitialLoad = true

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Bantay-TUI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("quick_notes.md")
        loadNote()
    }

    private func loadNote() {
        isInitialLoad = true
        defer { isInitialLoad = false }
        if let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8)
        {
            noteText = text
        } else {
            noteText =
                "# Quick Notes\n\n- Write ideas or code snippets here...\n- Auto-saved locally."
        }
    }

    private func scheduleSave() {
        guard !isInitialLoad else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveImmediate()
        }
    }

    public func saveImmediate() {
        guard let data = noteText.data(using: .utf8) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
