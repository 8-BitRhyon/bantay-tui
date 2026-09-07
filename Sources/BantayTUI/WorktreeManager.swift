import Foundation

/// Controller managing isolated Git worktrees for autonomous agent task execution.
/// Adopts Kun Chen's `firstmate` / `herdr worktree` pattern to prevent background agents
/// from dirtying the user's active working directory.
enum WorktreeManager {

    /// Generates a clean, branch-safe slug from a task title.
    static func branchSlug(from taskTitle: String, id: UUID = UUID()) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = taskTitle.lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .prefix(4)
            .joined(separator: "-")
        let suffix = String(id.uuidString.prefix(6)).lowercased()
        if cleaned.isEmpty {
            return "bantay/task-\(suffix)"
        }
        return "bantay/\(cleaned)-\(suffix)"
    }

    /// Creates an isolated Git worktree in `.worktrees/<branch>` under the repository root.
    static func createWorktree(
        repoRoot: String,
        branch: String
    ) async -> String? {
        let worktreeBase = (repoRoot as NSString).appendingPathComponent(".worktrees")
        try? FileManager.default.createDirectory(
            atPath: worktreeBase,
            withIntermediateDirectories: true
        )
        let worktreePath = (worktreeBase as NSString).appendingPathComponent(
            (branch as NSString).lastPathComponent
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["worktree", "add", "-b", branch, worktreePath]
        process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return worktreePath
            }
        } catch {
            return nil
        }
        return nil
    }

    /// Removes an existing Git worktree and prunes its entry.
    @discardableResult
    static func removeWorktree(
        repoRoot: String,
        worktreePath: String
    ) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["worktree", "remove", "--force", worktreePath]
        process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Lists active worktree paths for a given git repository.
    static func listWorktrees(repoRoot: String) async -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["worktree", "list", "--porcelain"]
        process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return [] }

            return text.split(separator: "\n").compactMap { line -> String? in
                if line.hasPrefix("worktree ") {
                    return String(line.dropFirst("worktree ".count))
                }
                return nil
            }
        } catch {
            return []
        }
    }
}
