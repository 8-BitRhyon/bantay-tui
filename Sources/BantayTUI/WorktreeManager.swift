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
        let (status, _) = runGit(
            ["worktree", "add", "-b", branch, worktreePath], repoRoot: repoRoot)
        return status == 0 ? worktreePath : nil
    }

    /// Removes an existing Git worktree and prunes its entry.
    @discardableResult
    static func removeWorktree(
        repoRoot: String,
        worktreePath: String
    ) async -> Bool {
        runGit(["worktree", "remove", "--force", worktreePath], repoRoot: repoRoot).status == 0
    }

    /// Lists active worktree paths for a given git repository.
    static func listWorktrees(repoRoot: String) async -> [String] {
        let (_, text) = runGit(["worktree", "list", "--porcelain"], repoRoot: repoRoot)
        return text.split(separator: "\n").compactMap { line in
            line.hasPrefix("worktree ") ? String(line.dropFirst("worktree ".count)) : nil
        }
    }

    // ponytail: single shared process runner for git CLI operations
    @discardableResult
    private static func runGit(_ args: [String], repoRoot: String) -> (
        status: Int32, output: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "")
        }
    }
}
